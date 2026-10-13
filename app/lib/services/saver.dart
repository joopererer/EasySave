// Save media into the photo album.
// Downloads go through HttpClient with the platform Referer attached, then
// into MediaStore via gal (no storage permission needed on Android 10+).

import 'dart:io';

import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';

import '../core/models.dart';

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

Future<File> _downloadToTemp(
  String url,
  String referer,
  String filename,
) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    request.headers.set(HttpHeaders.refererHeader, referer);
    request.headers.set(
      HttpHeaders.userAgentHeader,
      'Mozilla/5.0 (Linux; Android 10)',
    );
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

enum SaveFileStatus { pending, active, done, failed }

class SaveFileState {
  SaveFileState({required this.label, required this.status, this.error});

  final String label;
  SaveFileStatus status;
  String? error;

  SaveFileState copy() =>
      SaveFileState(label: label, status: status)..error = error;
}

class SaveProgress {
  SaveProgress({required this.done, required this.total, required this.files});

  final int done;
  final int total;
  final List<SaveFileState> files;
}

class SaveSummary {
  SaveSummary({required this.succeeded, required this.failed});
  final int succeeded;
  final int failed;
}

/// One downloadable file inside a save task.
class _Job {
  _Job({required this.label, required this.run});
  final String label;
  final Future<void> Function() run;
}

/// Save the selected items; reports per-file progress after each file.
/// [isCancelled] is checked between files (v1.1a: no background work).
/// v1: a live item is saved as its still image plus its motion video.
Future<SaveSummary> saveItems(
  ParsedPost post,
  List<int> selected, {
  Future<void> Function(SaveProgress progress)? onProgress,
  bool Function()? isCancelled,
  String album = 'EasySave',
  String Function(String label, int seq, String ext)? nameFor,
}) async {
  if (!await Gal.hasAccess()) {
    final granted = await Gal.requestAccess();
    if (!granted) throw const FileSystemException('没有相册访问权限');
  }
  final referer = _refererFor(post.platform);
  final jobs = <_Job>[];
  final counters = <String, int>{};
  String nextLabel(String kind) {
    final n = (counters[kind] ?? 0) + 1;
    counters[kind] = n;
    return '$kind $n';
  }

  String fileName(String label, int seq, String fallbackExt) =>
      nameFor?.call(label, seq, fallbackExt) ?? '${post.id}_$seq';

  var seq = 0;
  for (final index in selected) {
    final item = post.items[index];
    seq++;
    // Display order: CDN originals first (the rewritten ci primary is
    // occasionally slow/unreachable from mobile networks); ci stays last
    // as a fallback so nothing is lost when only it serves the bytes.
    final imageUrls = [...item.fallbacks, item.url];
    if (item.type == 'live' && item.videoUrl != null) {
      final base = nextLabel('Live');
      final stillSeq = seq;
      jobs.add(
        _Job(
          label: base,
          run: () => _saveOne(
            imageUrls,
            referer,
            fileName(base, stillSeq, 'jpg'),
            true,
            album,
          ),
        ),
      );
      jobs.add(
        _Job(
          label: base,
          run: () => _saveOne(
            [item.videoUrl!],
            referer,
            fileName(base, stillSeq, 'mp4'),
            false,
            album,
          ),
        ),
      );
    } else if (item.type == 'video') {
      final label = nextLabel('视频');
      final url = item.videoUrl ?? item.url;
      final videoUrls = item.videoUrl != null ? [url, ...imageUrls] : imageUrls;
      jobs.add(
        _Job(
          label: label,
          run: () => _saveOne(
            videoUrls,
            referer,
            fileName(label, seq, 'mp4'),
            false,
            album,
          ),
        ),
      );
    } else {
      final label = nextLabel('图片');
      jobs.add(
        _Job(
          label: label,
          run: () => _saveOne(
            imageUrls,
            referer,
            fileName(label, seq, 'jpg'),
            true,
            album,
          ),
        ),
      );
    }
  }

  final files = [
    for (final job in jobs)
      SaveFileState(label: job.label, status: SaveFileStatus.pending),
  ];
  Future<void> emit(int done) async {
    if (onProgress != null) {
      await onProgress(
        SaveProgress(
          done: done,
          total: jobs.length,
          files: [for (final f in files) f.copy()],
        ),
      );
    }
  }

  var done = 0;
  var failed = 0;
  // Bounded concurrency: 3 downloads at a time beats strict serial
  // without tripping CDN rate limits.
  const concurrency = 3;
  for (var i = 0; i < jobs.length; i += concurrency) {
    if (isCancelled?.call() == true) break;
    final batch = jobs.sublist(i, (i + concurrency).clamp(0, jobs.length));
    final batchIndex = i;
    final results = await Future.wait(
      batch.asMap().entries.map((entry) async {
        final file = files[batchIndex + entry.key];
        file.status = SaveFileStatus.active;
        try {
          await entry.value.run();
          return null;
        } catch (e) {
          return '$e';
        }
      }),
    );
    for (var k = 0; k < results.length; k++) {
      done++;
      final file = files[batchIndex + k];
      if (results[k] != null) {
        file.status = SaveFileStatus.failed;
        file.error = results[k];
        failed++;
      } else {
        file.status = SaveFileStatus.done;
      }
      await emit(done);
    }
  }
  return SaveSummary(succeeded: done - failed, failed: failed);
}

Future<void> _saveOne(
  List<String> urls,
  String referer,
  String baseName,
  bool isImage,
  String album,
) async {
  Object? lastError;
  for (final url in urls) {
    try {
      final ext = _extensionFor(url, isImage ? 'jpg' : 'mp4');
      final file = await _downloadToTemp(
        url,
        referer,
        'easysave_$baseName.$ext',
      );
      try {
        if (isImage) {
          await Gal.putImage(file.path, album: album);
        } else {
          await Gal.putVideo(file.path, album: album);
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

/// Save the post caption ("title\nbody") as a txt file next to app storage.
/// Returns the saved path, used by the completion state.
Future<String> saveCaptionTxt(ParsedPost post) async {
  final dir = await getApplicationDocumentsDirectory();
  final lines = [
    if ((post.title ?? '').isNotEmpty) post.title!,
    if ((post.caption ?? '').isNotEmpty) post.caption!,
  ];
  final file = File('${dir.path}/${post.id}.txt');
  await file.writeAsString(lines.join('\n\n'));
  return file.path;
}
