// Gallery import helpers. Downloads run through background_downloader;
// this file only moves finished temp files into MediaStore via gal
// (no storage permission needed on Android 10+) and saves captions.

import 'dart:io';

import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';

import '../core/models.dart';
import 'media_header_service.dart';

String refererFor(String platform) {
  if (platform == 'xhs') return 'https://www.xiaohongshu.com/';
  if (platform == 'instagram') return 'https://www.instagram.com/';
  if (platform == 'x') return 'https://x.com/';
  return '';
}


/// Import a finished temp download into the album, then delete the temp file.
///
/// Returns the saved asset's real MediaStore id, on-disk title, and relativePath
/// so the history record can point straight at it. `Gal.putImage` returns nothing
/// and the system may rename a file on name clashes (e.g. `x (1).jpg`), so we
/// locate the freshly saved asset right away instead of trusting the planned
/// filename. Returns nulls when lookup fails (e.g. no photo permission).
Future<({String? mediaId, String? title, String? relativePath})> saveToGallery(
  String path,
  bool isImage,
  String album,
) async {
  final basename = path.split(Platform.pathSeparator).last;
  final expectedName = _stripExtension(basename);
  try {
    if (isImage) {
      await Gal.putImage(path, album: album);
    } else {
      await Gal.putVideo(path, album: album);
    }
    final saved = await _locateJustSaved(expectedName, isImage, album);
    return saved;
  } finally {
    try {
      await File(path).delete();
    } catch (_) {
      // Best effort cleanup of the temp file.
    }
  }
}

String _stripExtension(String name) {
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}

/// Find the asset that was just written to [album]: the newest item whose
/// title matches the planned base name, falling back to the newest asset in
/// the album (the file we just saved is the most recent). MediaStore indexing
/// can lag a beat behind the write, so a couple of short retries help.
Future<({String? mediaId, String? title, String? relativePath})> _locateJustSaved(
  String expectedName,
  bool isImage,
  String album,
) async {
  // MediaStore can lag a beat behind the write, and the title match may only
  // appear once indexing catches up. Retry a few times before giving up so a
  // rapid multi-file import doesn't grab the wrong (previous) asset.
  for (var attempt = 0; attempt < 5; attempt++) {
    if (attempt > 0) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    final found = await _locateJustSavedOnce(expectedName, isImage, album);
    if (found.mediaId != null) return found;
  }
  return (mediaId: null, title: null, relativePath: null);
}

Future<({String? mediaId, String? title, String? relativePath})> _locateJustSavedOnce(
  String expectedName,
  bool isImage,
  String album,
) async {
  try {
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.common,
      hasAll: true,
      // Title is required to match the just-saved file by name.
      filterOption: FilterOptionGroup(
        imageOption: const FilterOption(needTitle: true),
        videoOption: const FilterOption(needTitle: true),
      ),
    );
    AssetPathEntity? target;
    AssetPathEntity? all;
    for (final p in paths) {
      if (p.name.trim().toLowerCase() == album.trim().toLowerCase()) {
        target = p;
      }
      if (p.isAll) all = p;
    }
    // Prefer the target album; fall back to "all" so a renamed or
    // differently-visible album can't strand the saved file.
    for (final path in [target, all]) {
      if (path == null) continue;
      final found = await _matchNewestIn(path, expectedName, isImage);
      if (found.mediaId != null) return found;
    }
    return (mediaId: null, title: null, relativePath: null);
  } catch (_) {
    return (mediaId: null, title: null, relativePath: null);
  }
}

Future<({String? mediaId, String? title, String? relativePath})> _matchNewestIn(
  AssetPathEntity path,
  String expectedName,
  bool isImage,
) async {
  final count = await path.assetCountAsync;
  if (count <= 0) return (mediaId: null, title: null, relativePath: null);
  // Newest first: scan a small window, the saved file is at the very front.
  final list = await path.getAssetListRange(
    start: 0,
    end: count < 30 ? count : 30,
  );
  final want = expectedName.toLowerCase();
  AssetEntity? exact;
  AssetEntity? renamed;
  // The file was written seconds ago; only accept a fallback that is at
  // least plausibly ours, never someone else's old photo.
  final cutoff = DateTime.now().subtract(const Duration(minutes: 2));
  for (final a in list) {
    final isImg = a.type == AssetType.image;
    final isVid = a.type == AssetType.video;
    if (isImage ? !isImg : !isVid) continue;
    DateTime created;
    try {
      created = a.createDateTime;
    } catch (_) {
      continue;
    }
    if (created.isBefore(cutoff)) continue;
    final title = (a.title ?? '').trim().toLowerCase();
    if (title == want || _stripExtension(title) == want) {
      exact = a;
      break;
    }
    // The system appends ` (1)`-style suffixes on name clashes; those still
    // start from our planned base name and are unambiguous.
    final stem = _stripExtension(title);
    if (stem.startsWith('$want (')) renamed ??= a;
  }
  // Only trust a title match. Accepting "the newest asset of this type" was
  // the source of a nasty bug: when several files are imported in quick
  // succession, MediaStore indexing lags and the newest item is still the
  // PREVIOUS file, so multiple items ended up sharing one media id (history
  // showed the same thumbnail for several distinct photos). Returning null
  // instead lets the caller retry until the right file is indexed.
  final chosen = exact ?? renamed;
  if (chosen == null) return (mediaId: null, title: null, relativePath: null);

  String? relPath;
  try {
    relPath = chosen.relativePath;
    if (relPath == null || relPath.isEmpty) {
      final info = await MediaHeaderService.queryAlbum(chosen.id);
      relPath = info?.relativePath;
    }
  } catch (_) {
    relPath = null;
  }
  return (mediaId: chosen.id, title: chosen.title, relativePath: relPath);
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
