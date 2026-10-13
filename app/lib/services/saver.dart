// Save media into the "EasySave" photo album.
// Downloads go through HttpClient with the platform Referer attached, then
// into MediaStore via gal (no storage permission needed on Android 10+).

import 'dart:io';

import 'package:gal/gal.dart';

import '../core/models.dart';

const String albumName = 'EasySave';

String _refererFor(String platform) => platform == 'xhs'
    ? 'https://www.xiaohongshu.com/'
    : 'https://www.instagram.com/';

String _extensionFor(String url, String fallback) {
  final path = Uri.tryParse(url)?.path ?? '';
  final base = path.split('/').isEmpty ? '' : path.split('/').last;
  final dot = base.lastIndexOf('.');
  if (dot < 0) return fallback;
  final ext = base.substring(dot + 1).toLowerCase();
  return RegExp(r'^[a-z0-9]{2,5}$').hasMatch(ext) ? ext : fallback;
}

Future<File> _downloadToTemp(String url, String referer, String filename) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    request.headers.set(HttpHeaders.refererHeader, referer);
    request.headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0 (Linux; Android 10)');
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('下载失败（HTTP ${response.statusCode}）：$url');
    }
    final bytes = await response.fold<List<int>>(
      <int>[],
      (previous, element) => previous..addAll(element),
    );
    final file = File('${Directory.systemTemp.path}/$filename');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  } finally {
    client.close(force: true);
  }
}

class SaveProgress {
  SaveProgress({required this.done, required this.total});
  final int done;
  final int total;
}

/// Save the selected items; reports progress after each file.
/// v1: a live item is saved as its still image plus its motion video.
Future<void> saveItems(
  ParsedPost post,
  List<int> selected,
  Future<void> Function(SaveProgress progress) onProgress,
) async {
  if (!await Gal.hasAccess()) {
    final granted = await Gal.requestAccess();
    if (!granted) throw const FileSystemException('没有相册访问权限');
  }
  final referer = _refererFor(post.platform);
  var done = 0;
  final jobs = <Future<void> Function()>[];
  var total = 0;
  for (var i = 0; i < selected.length; i++) {
    final item = post.items[selected[i]];
    final seq = i + 1;
    // Display order: CDN originals first (the rewritten ci primary is
    // occasionally slow/unreachable from mobile networks); ci stays last
    // as a fallback so nothing is lost when only it serves the bytes.
    final imageUrls = [...item.fallbacks, item.url];
    if (item.type == 'live' && item.videoUrl != null) {
      total += 2;
      jobs.add(() => _saveOne(imageUrls, referer, '${post.id}_$seq.jpg', true));
      jobs.add(() => _saveOne([item.videoUrl!], referer, '${post.id}_${seq}_live.mp4', false));
    } else if (item.type == 'video') {
      total += 1;
      final url = item.videoUrl ?? item.url;
      final videoUrls = item.videoUrl != null ? [url, ...imageUrls] : imageUrls;
      jobs.add(() => _saveOne(videoUrls, referer, '${post.id}_$seq.mp4', false));
    } else {
      total += 1;
      jobs.add(() => _saveOne(imageUrls, referer, '${post.id}_$seq.jpg', true));
    }
  }
  // Bounded concurrency: 3 downloads at a time beats strict serial
  // without tripping CDN rate limits.
  const concurrency = 3;
  var failed = <String>[];
  for (var i = 0; i < jobs.length; i += concurrency) {
    final batch = jobs.sublist(i, (i + concurrency).clamp(0, jobs.length));
    final results = await Future.wait(
      batch.map((job) async {
        try {
          await job();
          return null;
        } catch (e) {
          return '$e';
        }
      }),
    );
    for (final error in results) {
      done++;
      if (error != null) failed.add(error);
      await onProgress(SaveProgress(done: done, total: total));
    }
  }
  if (failed.isNotEmpty) {
    throw FileSystemException('其中 ${failed.length} 个文件保存失败：${failed.first}');
  }
}

Future<void> _saveOne(
  List<String> urls,
  String referer,
  String fallbackName,
  bool isImage,
) async {
  Object? lastError;
  for (final url in urls) {
    try {
      final ext = _extensionFor(url, isImage ? 'jpg' : 'mp4');
      final name = fallbackName.replaceFirst(RegExp(r'\.(jpg|mp4)$'), '.$ext');
      final file = await _downloadToTemp(url, referer, 'easysave_$name');
      try {
        if (isImage) {
          await Gal.putImage(file.path, album: albumName);
        } else {
          await Gal.putVideo(file.path, album: albumName);
        }
      } finally {
        try {
          await file.delete();
        } catch (_) {
          // Best effort cleanup of the temp file.
        }
      }
      return;
    } on Exception catch (e) {
      lastError = e;
    }
  }
  throw lastError ?? HttpException('下载失败：${urls.first}');
}
