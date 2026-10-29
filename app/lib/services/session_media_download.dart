import 'dart:async';
import 'dart:io';
import '../core/media_request.dart';
import 'media_request_policy.dart';

const expiredMediaMessage = '链接已过期，请重新解析';
const interruptedMediaMessage = '需要重新解析';

/// Only fixed messages leave the transport. Never expose request objects,
/// response headers or exceptions (which may contain credentials).
class SessionDownloadException implements Exception {
  const SessionDownloadException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => message;
}

class SessionDownloadCanceled implements Exception {
  const SessionDownloadCanceled();
  @override
  String toString() => '下载已取消';
}

/// One in-process transfer. No task database, cookie jar, resume data or logger.
/// [cancel] closes the client even while waiting for headers or stalled bytes.
class SessionMediaDownload {
  HttpClient? _client;
  bool _canceled = false;
  final _finished = Completer<void>();

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
          for (final header in authorized.wireHeaders.entries) {
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
