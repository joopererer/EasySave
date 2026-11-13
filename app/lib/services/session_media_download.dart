import 'dart:async';
import 'dart:io';
import '../core/media_request.dart';
import 'media_request_policy.dart';
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

  Future<void> download({
    required String url,
    required File destination,
    Future<String> Function()? readCookie,
    MediaRequestPolicy? policy,
    MediaRequestResource? resource,
    required void Function(double progress) onProgress,
  }) async {
    RandomAccessFile? output;
    var complete = false;
    try {
      if (_canceled) throw const SessionDownloadCanceled();
      var authorized = policy == null
          ? null
          : await policy.authorize(resource!);
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
      if (response.statusCode == 403) {
        throw const SessionDownloadException(
          expiredMediaMessage,
          statusCode: 403,
        );
      }
      if (response.statusCode != 200) {
        throw SessionDownloadException(
          '下载失败，请重新解析',
          statusCode: response.statusCode,
        );
      }
      await destination.parent.create(recursive: true);
      output = await destination.open(mode: FileMode.write);
      var received = 0;
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        if (_canceled) throw const SessionDownloadCanceled();
        await output.writeFrom(chunk);
        received += chunk.length;
        onProgress(
          response.contentLength > 0
              ? (received / response.contentLength).clamp(0.0, 1.0)
              : 0,
        );
      }
      if (_canceled) throw const SessionDownloadCanceled();
      if (received == 0 ||
          (response.contentLength >= 0 && received != response.contentLength)) {
        throw const SessionDownloadException('下载不完整，请重新解析');
      }
      await output.flush();
      complete = true;
    } on SessionDownloadException {
      rethrow;
    } on SessionDownloadCanceled {
      rethrow;
    } on MediaPolicyException {
      rethrow;
    } on TimeoutException {
      // A connect, header or byte timeout: the peer never answered. Retrying
      // the URL by hand is the user's choice, not the app's verdict on it.
      if (_canceled) throw const SessionDownloadCanceled();
      throw const SessionDownloadException(
        networkUnavailableMessage,
        network: true,
      );
    } on SocketException {
      // No route, DNS failure, refused or reset connection: the network could
      // not be reached (v1.11 batch 3).
      if (_canceled) throw const SessionDownloadCanceled();
      throw const SessionDownloadException(
        networkUnavailableMessage,
        network: true,
      );
    } on TlsException {
      if (_canceled) throw const SessionDownloadCanceled();
      throw const SessionDownloadException(
        networkUnavailableMessage,
        network: true,
      );
    } on HttpException {
      // `HttpException` covers a connection closed before the headers or the
      // body completed — a transport failure, never a content verdict.
      if (_canceled) throw const SessionDownloadCanceled();
      throw const SessionDownloadException(
        networkUnavailableMessage,
        network: true,
      );
    } catch (_) {
      if (_canceled) throw const SessionDownloadCanceled();
      throw const SessionDownloadException('下载失败，请重新解析');
    } finally {
      _client?.close(force: true);
      _client = null;
      try {
        await output?.close();
      } finally {
        try {
          if (!complete && await destination.exists()) {
            await destination.delete();
          }
        } finally {
          _finished.complete();
        }
      }
    }
  }
}
