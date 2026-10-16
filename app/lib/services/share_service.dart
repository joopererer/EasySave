// Share a finished batch to other apps (roadmap v1.2, UniPost handoff).
// Text (author, post link, title, caption) always ships; completed image
// files are re-fetched over HTTP into the app cache and attached. Gallery
// files are not read back — the temp files were deleted after import and
// MediaStore paths are not ours to share.

import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'download_manager.dart';
import 'saver.dart';

/// Share text for a finished batch: author, title, caption, post link.
String shareTextFor(DownloadBatch batch) {
  final lines = <String>[];
  final author = batch.authorName;
  if (author != null && author.isNotEmpty) lines.add('作者：$author');
  if ((batch.title ?? '').isNotEmpty) lines.add(batch.title!);
  if ((batch.caption ?? '').isNotEmpty) lines.add(batch.caption!);
  lines.add('原帖：${batch.postUrl}');
  return lines.join('\n');
}

/// Completed image jobs that can be attached as files.
List<DownloadJob> shareableImageJobs(DownloadBatch batch) => [
  for (final job in batch.jobs)
    if (job.state == JobState.done && job.isImage) job,
];

/// Re-fetch a completed file's bytes (first reachable URL wins) into the
/// app cache so share_plus can attach it. Returns null when every URL
/// fails — the caller then shares text only instead of erroring.
Future<XFile?> fetchShareFile(
  DownloadJob job,
  String referer, {
  http.Client? client,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final owned = client == null;
  final httpClient = client ?? http.Client();
  try {
    for (final url in job.urls) {
      try {
        final response = await httpClient
            .get(Uri.parse(url), headers: {'Referer': referer})
            .timeout(timeout);
        if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
          continue;
        }
        final dir = await getTemporaryDirectory();
        final file = File('${dir.path}/share_${job.filename}');
        await file.writeAsBytes(response.bodyBytes, flush: true);
        return XFile(file.path, name: job.filename);
      } catch (_) {
        // Try the next URL.
      }
    }
    return null;
  } finally {
    if (owned) httpClient.close();
  }
}

/// Share a finished batch: text always, images when re-fetchable.
/// Returns true when the system sheet was shown.
Future<bool> shareBatch(DownloadBatch batch, {http.Client? client}) async {
  final text = shareTextFor(batch);
  final files = <XFile>[];
  for (final job in shareableImageJobs(batch)) {
    final file = await fetchShareFile(
      job,
      refererFor(batch.platform),
      client: client,
    );
    if (file != null) files.add(file);
  }
  if (files.isEmpty) {
    await SharePlus.instance.share(ShareParams(text: text));
  } else {
    await SharePlus.instance.share(ShareParams(text: text, files: files));
  }
  return true;
}
