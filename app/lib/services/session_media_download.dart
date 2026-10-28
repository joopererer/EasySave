import 'dart:async';
import 'dart:io';

const expiredMediaMessage = '链接已过期，请重新解析';
const interruptedMediaMessage = '需要重新解析';

bool mediaUrlExpired(String url, {DateTime? now}) {
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  final seconds = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
  for (final entry in uri.queryParametersAll.entries) {
    if (!{'expire', 'x-expires'}.contains(entry.key.toLowerCase())) continue;
    for (final value in entry.value) {
      final expiry = int.tryParse(value);
      if (expiry != null && expiry <= seconds) return true;
    }
  }
  return false;
}

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
    required Future<String> Function() readCookie,
    required void Function(double progress) onProgress,
  }) async {
    RandomAccessFile? output;
    var complete = false;
    try {
      if (_canceled) throw const SessionDownloadCanceled();
      if (mediaUrlExpired(url)) {
        throw const SessionDownloadException(expiredMediaMessage);
      }
      final client = _client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 30)
        ..autoUncompress = false;
      final request = await client.getUrl(Uri.parse(url));
      // Do not forward TikTok credentials to a redirect target. A newly parsed
      // direct CDN address is required instead.
      request.followRedirects = false;
      request.headers.set(HttpHeaders.refererHeader, 'https://www.tiktok.com/');
      request.headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0 (Linux; Android 10)');
      final cookie = await readCookie();
      if (_canceled) throw const SessionDownloadCanceled();
      if (cookie.isNotEmpty) request.headers.set(HttpHeaders.cookieHeader, cookie);
      final response = await request.close().timeout(const Duration(seconds: 30));
      if (response.statusCode == 403) {
        throw const SessionDownloadException(expiredMediaMessage, statusCode: 403);
      }
      if (response.statusCode != 200) {
        throw SessionDownloadException('下载失败，请重新解析', statusCode: response.statusCode);
      }
      await destination.parent.create(recursive: true);
      output = await destination.open(mode: FileMode.write);
      var received = 0;
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        if (_canceled) throw const SessionDownloadCanceled();
        await output.writeFrom(chunk);
        received += chunk.length;
        onProgress(response.contentLength > 0
            ? (received / response.contentLength).clamp(0.0, 1.0) : 0);
      }
      if (_canceled) throw const SessionDownloadCanceled();
      if (received == 0 || (response.contentLength >= 0 && received != response.contentLength)) {
        throw const SessionDownloadException('下载不完整，请重新解析');
      }
      await output.flush();
      complete = true;
    } on SessionDownloadException {
      rethrow;
    } on SessionDownloadCanceled {
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
          if (!complete && await destination.exists()) await destination.delete();
        } finally {
          _finished.complete();
        }
      }
    }
  }
}
