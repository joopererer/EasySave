import 'dart:async';
import 'dart:io';
import '../core/media_request.dart';
import 'media_request_policy.dart';
import 'resumable_download_store.dart';
import 'transfer_headers.dart';

const expiredMediaMessage = '链接已过期，请重新解析';
const interruptedMediaMessage = '需要重新解析';
const networkUnavailableMessage = '网络不可用，请联网后重试';

/// Only fixed messages leave the transport. Never expose request objects,
/// response headers or exceptions (which may contain credentials).
class SessionDownloadException implements Exception {
  const SessionDownloadException(this.message, {this.statusCode, this.network = false});
  final String message;
  final int? statusCode;

  /// The connection could not be reached or broke mid-transfer (v1.11 batch 3):
  /// no network, DNS failure, refused or reset connection, a timeout or a TLS
  /// handshake that never finished. Such a failure says nothing about the
  /// media, so it must never be recorded as a content verdict.
  final bool network;

  @override
  String toString() => message;
}

/// What [DownloadManager] needs from one in-process transfer: a download it can
/// start and a cancel it can ask for. The real one is [SessionMediaDownload];
/// tests substitute their own to script a connection that drops.
abstract class SessionTransfer {
  Future<void> download({
    required String url,
    required File destination,
    Future<String> Function()? readCookie,
    MediaRequestPolicy? policy,
    MediaRequestResource? resource,
    required void Function(double progress) onProgress,
    String? jobKey,
    int? itemIndex,
  });

  Future<void> cancel();
}

class SessionDownloadCanceled implements Exception {
  const SessionDownloadCanceled();
  @override
  String toString() => '下载已取消';
}

/// One in-process transfer. No task database, cookie jar, resume data or logger.
/// [cancel] closes the client even while waiting for headers or stalled bytes.
class SessionMediaDownload implements SessionTransfer {
  HttpClient? _client;
  bool _canceled = false;
  final _finished = Completer<void>();

  @override
  Future<void> cancel() async {
    _canceled = true;
    _client?.close(force: true);
    await _finished.future;
  }

  @override
  Future<void> download({
    required String url,
    required File destination,
    Future<String> Function()? readCookie,
    MediaRequestPolicy? policy,
    MediaRequestResource? resource,
    required void Function(double progress) onProgress,
    String? jobKey,
    int? itemIndex,
  }) async {
    RandomAccessFile? output;
    var complete = false;
    final store = ResumableDownloadStore.instance;
    File? partialFile;
    ResumeMetadata? initialMeta;
    var isResumeAttempt = false;
    var existingBytes = 0;
    String? currentValidator;
    var activeOutputIsPartial = false;
    var received = 0;
    var expectedTotal = -1;

    Future<void> safeCloseOutput() async {
      try {
        await output?.close();
        output = null;
      } catch (_) {}
    }

    try {
      if (_canceled) throw const SessionDownloadCanceled();
      if (jobKey != null) {
        partialFile = await store.partialFileFor(jobKey);
        initialMeta = await store.readMetadata(jobKey);
        if (await partialFile.exists()) {
          final len = await partialFile.length();
          if (len >= kResumableMinBytes &&
              initialMeta != null &&
              initialMeta.validator.isNotEmpty) {
            isResumeAttempt = true;
            existingBytes = len;
            currentValidator = initialMeta.validator;
          } else if (len > 0 && len < kResumableMinBytes) {
            await store.cleanForJob(jobKey);
          }
        }
      }

      final roleStr = resource?.role.name ?? 'video';
      final idx = itemIndex ?? 0;

      MediaRequestResource? reqResource = resource;
      if (isResumeAttempt && resource != null && currentValidator != null) {
        reqResource = MediaRequestResource(
          role: resource.role,
          url: resource.url,
          fallbackFor: resource.fallbackFor,
          request: MediaRequestRequirements(
            headers: {
              ...resource.request.headers,
              'Range': 'bytes=$existingBytes-',
              'If-Range': currentValidator,
            },
            cookieDomains: resource.request.cookieDomains,
            expiresAt: resource.request.expiresAt,
            transport: resource.request.transport,
            resumable: resource.request.resumable,
          ),
        );
      }

      var authorized = policy == null
          ? null
          : await policy.authorize(reqResource ?? resource!);
      final client = _client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 30)
        ..autoUncompress = false;
      HttpClientResponse response;
      var current = authorized?.uri ?? Uri.parse(url);
      for (var hop = 0; ; hop++) {
        final request = await client.getUrl(current);
        request.followRedirects = false;
        if (authorized != null) {
          final headers = unifiedTransferHeaders(authorized.wireHeaders);
          for (final header in headers.entries) {
            request.headers.set(header.key, header.value);
          }
        } else {
          if (isResumeAttempt && currentValidator != null) {
            request.headers.set(HttpHeaders.rangeHeader, 'bytes=$existingBytes-');
            request.headers.set('If-Range', currentValidator);
          }
          final cookie = await readCookie?.call() ?? '';
          if (cookie.isNotEmpty) {
            request.headers.set(HttpHeaders.cookieHeader, cookie);
          }
        }
        if (_canceled) throw const SessionDownloadCanceled();
        response = await request.close().timeout(const Duration(seconds: 30));
        if (response.statusCode < 300 || response.statusCode >= 400) break;
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.drain<void>();
        if (authorized == null || policy == null) {
          throw const SessionDownloadException('下载失败，请重新解析');
        }
        if (location == null || hop >= 5) {
          policy.rejectRedirect(current);
        }
        authorized = await policy.redirect(authorized, location);
        current = authorized.uri;
      }

      if (response.statusCode == 403 || response.statusCode == 410) {
        if (isResumeAttempt && jobKey != null) {
          ResumableDownloadStore.logResume(
            index: idx,
            role: roleStr,
            fromBytes: existingBytes,
            total: -1,
            result: 'restart',
            reason: 'expired',
          );
          await store.cleanForJob(jobKey);
        }
        throw SessionDownloadException(
          expiredMediaMessage,
          statusCode: response.statusCode,
        );
      }

      String? respValidator = response.headers.value(HttpHeaders.etagHeader) ??
          response.headers.value(HttpHeaders.lastModifiedHeader);
      if (respValidator != null) {
        if (!respValidator.startsWith('"') &&
            !respValidator.startsWith('W/"') &&
            !respValidator.contains('GMT')) {
          respValidator = '"$respValidator"';
        }
        currentValidator = respValidator;
      }

      final targetFile = partialFile ?? destination;
      activeOutputIsPartial = partialFile != null;
      await targetFile.parent.create(recursive: true);

      if (response.statusCode == 206) {
        final contentRange =
            response.headers.value(HttpHeaders.contentRangeHeader) ?? '';
        final match =
            RegExp(r'bytes\s+(\d+)-(\d+)/(?:\*|(\d+))').firstMatch(contentRange);
        final start = match != null ? int.tryParse(match.group(1)!) : null;
        final total = match != null && match.group(3) != null
            ? int.tryParse(match.group(3)!)
            : null;
        if (isResumeAttempt && start == existingBytes) {
          expectedTotal = total ?? (existingBytes + response.contentLength);
          ResumableDownloadStore.logResume(
            index: idx,
            role: roleStr,
            fromBytes: existingBytes,
            total: expectedTotal,
            result: 'resumed',
            reason: 'range_accepted',
          );
          output = await targetFile.open(mode: FileMode.append);
          received = existingBytes;
        } else {
          if (isResumeAttempt && jobKey != null) {
            ResumableDownloadStore.logResume(
              index: idx,
              role: roleStr,
              fromBytes: existingBytes,
              total: total ?? response.contentLength,
              result: 'restart',
              reason: 'validator_changed',
            );
            await store.cleanForJob(jobKey);
          }
          expectedTotal = response.contentLength;
          output = await targetFile.open(mode: FileMode.write);
          received = 0;
        }
      } else if (response.statusCode == 200) {
        if (isResumeAttempt && jobKey != null) {
          final reason = (initialMeta != null &&
                  respValidator != null &&
                  respValidator != initialMeta.validator)
              ? 'validator_changed'
              : 'status_200';
          ResumableDownloadStore.logResume(
            index: idx,
            role: roleStr,
            fromBytes: existingBytes,
            total: response.contentLength,
            result: 'restart',
            reason: reason,
          );
          await store.cleanForJob(jobKey);
        }
        expectedTotal = response.contentLength;
        output = await targetFile.open(mode: FileMode.write);
        received = 0;
      } else {
        throw SessionDownloadException(
          '下载失败，请重新解析',
          statusCode: response.statusCode,
        );
      }

      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        if (_canceled) throw const SessionDownloadCanceled();
        await output?.writeFrom(chunk);
        received += chunk.length;
        onProgress(
          expectedTotal > 0
              ? (received / expectedTotal).clamp(0.0, 1.0)
              : 0,
        );
      }

      if (_canceled) throw const SessionDownloadCanceled();
      if (received == 0 ||
          (expectedTotal >= 0 && received != expectedTotal)) {
        throw const SessionDownloadException('下载不完整，请重新解析');
      }

      await output?.flush();
      await output?.close();
      output = null;

      if (partialFile != null && targetFile.path != destination.path) {
        await destination.parent.create(recursive: true);
        if (await destination.exists()) await destination.delete();
        await targetFile.copy(destination.path);
        if (jobKey != null) await store.cleanForJob(jobKey);
      }

      complete = true;
    } on SessionDownloadCanceled {
      await safeCloseOutput();
      if (jobKey != null) await store.cleanForJob(jobKey);
      rethrow;
    } on SessionDownloadException {
      await safeCloseOutput();
      rethrow;
    } on MediaPolicyException {
      await safeCloseOutput();
      if (jobKey != null) await store.cleanForJob(jobKey);
      rethrow;
    } on TimeoutException {
      await safeCloseOutput();
      if (_canceled) {
        if (jobKey != null) await store.cleanForJob(jobKey);
        throw const SessionDownloadCanceled();
      }
      await _handleNetworkInterruption(
        store,
        jobKey,
        received,
        expectedTotal,
        currentValidator,
      );
      throw const SessionDownloadException(
        networkUnavailableMessage,
        network: true,
      );
    } on SocketException {
      await safeCloseOutput();
      if (_canceled) {
        if (jobKey != null) await store.cleanForJob(jobKey);
        throw const SessionDownloadCanceled();
      }
      await _handleNetworkInterruption(
        store,
        jobKey,
        received,
        expectedTotal,
        currentValidator,
      );
      throw const SessionDownloadException(
        networkUnavailableMessage,
        network: true,
      );
    } on TlsException {
      await safeCloseOutput();
      if (_canceled) {
        if (jobKey != null) await store.cleanForJob(jobKey);
        throw const SessionDownloadCanceled();
      }
      await _handleNetworkInterruption(
        store,
        jobKey,
        received,
        expectedTotal,
        currentValidator,
      );
      throw const SessionDownloadException(
        networkUnavailableMessage,
        network: true,
      );
    } on HttpException {
      await safeCloseOutput();
      if (_canceled) {
        if (jobKey != null) await store.cleanForJob(jobKey);
        throw const SessionDownloadCanceled();
      }
      await _handleNetworkInterruption(
        store,
        jobKey,
        received,
        expectedTotal,
        currentValidator,
      );
      throw const SessionDownloadException(
        networkUnavailableMessage,
        network: true,
      );
    } catch (_) {
      await safeCloseOutput();
      if (_canceled) {
        if (jobKey != null) await store.cleanForJob(jobKey);
        throw const SessionDownloadCanceled();
      }
      if (jobKey != null) await store.cleanForJob(jobKey);
      throw const SessionDownloadException('下载失败，请重新解析');
    } finally {
      _client?.close(force: true);
      _client = null;
      try {
        await safeCloseOutput();
      } finally {
        try {
          if (!complete) {
            if (!activeOutputIsPartial && await destination.exists()) {
              await destination.delete();
            }
          }
        } finally {
          _finished.complete();
        }
      }
    }
  }

  Future<void> _handleNetworkInterruption(
    ResumableDownloadStore store,
    String? jobKey,
    int received,
    int total,
    String? validator,
  ) async {
    if (jobKey == null) return;
    if (received >= kResumableMinBytes &&
        validator != null &&
        validator.isNotEmpty) {
      await store.writeMetadata(
        jobKey,
        ResumeMetadata(
          validator: validator,
          totalBytes: total,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    } else {
      await store.cleanForJob(jobKey);
    }
  }
}
