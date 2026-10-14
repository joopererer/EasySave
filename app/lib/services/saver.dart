// Gallery import helpers. Downloads run through background_downloader;
// this file only moves finished temp files into MediaStore via gal
// (no storage permission needed on Android 10+) and saves captions.

import 'dart:io';

import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';

import '../core/models.dart';

String refererFor(String platform) => platform == 'xhs'
    ? 'https://www.xiaohongshu.com/'
    : 'https://www.instagram.com/';

/// Import a finished temp download into the album, then delete the temp.
Future<void> saveToGallery(String path, bool isImage, String album) async {
  try {
    if (isImage) {
      await Gal.putImage(path, album: album);
    } else {
      await Gal.putVideo(path, album: album);
    }
  } finally {
    try {
      await File(path).delete();
    } catch (_) {
      // Best effort cleanup of the temp file.
    }
  }
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
