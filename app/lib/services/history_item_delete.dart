// Delete one item of a stored post from the viewer (v1.11 batch 4).
//
// Two modes, both ending in the same state:
//   * 仅删除记录 — the rows become [FileStatus.deleted]; the album file stays and
//     the user can undo the whole thing from the snack bar;
//   * 同时删除相册文件 — the album file goes through the same system
//     confirmation the multi-select delete uses, and the rows are marked
//     deleted as well. This one cannot be undone.
//
// A deleted item is not "missing": it never shows up in the viewer again, is
// never counted as a missing file and is never offered for a re-download.

import 'package:flutter/foundation.dart';

import '../core/dev_log.dart';
import 'gallery_locator_service.dart';
import 'history_db.dart';
import 'live_pairs.dart';
import 'media_delete_service.dart';

/// What one item deletion did.
class ItemDeletionOutcome {
  ItemDeletionOutcome({
    required this.ok,
    this.before = const [],
    this.after = const [],
    this.albumOutcome,
    this.problem,
    this.visibleRemaining = 0,
    this.deleteAlbumFiles = false,
  });

  /// The rows were written (with or without the album file).
  final bool ok;

  /// Rows of the record before and after the change (the undo restores these).
  final List<HistoryFile> before;
  final List<HistoryFile> after;

  /// What the system delete flow reported, when it was asked.
  final MediaDeleteOutcome? albumOutcome;

  /// User-facing sentence when the album file was kept.
  final String? problem;

  /// Items of the post still visible after the change (Live pairs count once).
  final int visibleRemaining;

  /// Whether the album file was part of the request (it cannot be undone).
  final bool deleteAlbumFiles;
}

/// The stored rows that belong to [itemIndex] (0-based, as the viewer shows it).
///
/// A Live photo's still and motion clip share one index, so a delete removes
/// the pair, never half of it.
List<HistoryFile> historyRowsForItem(HistoryRecord record, int itemIndex) {
  final visible = record.visibleFiles;
  final is1Based = visible.isNotEmpty && visible.every((f) => f.itemIndex > 0);
  final raw = is1Based ? itemIndex + 1 : itemIndex;
  final byOriginal = visible.where((f) => f.itemIndex == raw).toList();
  if (byOriginal.isNotEmpty) return byOriginal;
  // Legacy rows predating the 1-based rule use the viewer's own index.
  return visible.where((f) => f.itemIndex == itemIndex).toList();
}

/// Delete one item of [record].
///
/// [deleteMedia] is the platform call, injectable for tests. Nothing is
/// written when the rows cannot be found, so a stale tap cannot silently mark
/// half a post.
Future<ItemDeletionOutcome> deleteHistoryItem(
  HistoryRecord record, {
  required int itemIndex,
  required bool deleteAlbumFiles,
  HistoryDb? database,
  GalleryLocatorService? locator,
  Future<MediaDeleteOutcome> Function(List<MediaRef> media)? deleteMedia,
}) async {
  final id = record.id;
  if (id == null) return ItemDeletionOutcome(ok: false);

  return HistoryDb.withPostLock(id, () async {
    final rows = historyRowsForItem(record, itemIndex);
    if (rows.isEmpty) return ItemDeletionOutcome(ok: false);

    MediaDeleteOutcome? album;
    String? problem;
    if (deleteAlbumFiles) {
      final refs = deletableRefs(rows);
      if (refs.isEmpty) {
        // A row the album never located cannot be deleted by id: say so instead
        // of pretending the file went away.
        problem = '相册中未找到这个文件，已仅删除记录';
      } else {
        final call =
            deleteMedia ?? MediaDeleteService.instance.deleteMedia;
        album = await call(refs);
        if (!album.deletedAll) {
          problem = '${album.problem ?? '相册文件未删除'}，已仅删除记录';
        }
      }
    }

    final before = record.files;
    final target = rows.map((r) => '${r.itemIndex}_${r.isImage}').toSet();
    final after = [
      for (final file in before)
        target.contains('${file.itemIndex}_${file.isImage}') &&
                isVisibleHistoryFile(file)
            ? file.copyWith(status: FileStatus.deleted)
            : file,
    ];

    final db = database ?? await HistoryDb.instance();
    await db.updateFiles(id, after, source: 'viewer-item-delete');

    final liveCount = pairSavedMedia(rows).where((e) => e.isLive).length;
    final deletedFiles = album != null ? (album.requested - album.remaining) : 0;
    final failedFiles = album != null ? album.remaining : 0;
    DevLog.write(
      'HIST',
      'viewer-delete post=${record.postId} selectedItems=1 files=${rows.length} live=$liveCount deletedFiles=$deletedFiles failedFiles=$failedFiles',
    );

    return ItemDeletionOutcome(
      ok: true,
      before: before,
      after: after,
      albumOutcome: album,
      problem: problem,
      visibleRemaining: pairSavedMedia(
        after.where(isVisibleHistoryFile),
      ).length,
      deleteAlbumFiles: deleteAlbumFiles,
    );
  });
}

/// Outcome of deleting multiple history items from the viewer.
class BatchItemDeletionOutcome {
  const BatchItemDeletionOutcome({
    required this.ok,
    this.cancelled = false,
    this.succeededIndices = const {},
    this.failedIndices = const {},
    this.before = const [],
    this.after = const [],
    this.albumOutcome,
    this.problem,
    this.deleteAlbumFiles = false,
  });

  final bool ok;
  final bool cancelled;
  final Set<int> succeededIndices;
  final Set<int> failedIndices;
  final List<HistoryFile> before;
  final List<HistoryFile> after;
  final MediaDeleteOutcome? albumOutcome;
  final String? problem;
  final bool deleteAlbumFiles;
}

/// Delete multiple post items from [record], optionally removing their album
/// files in a single batch operation through [MediaDeleteService].
Future<BatchItemDeletionOutcome> deleteHistoryItems(
  HistoryRecord record, {
  required Set<int> itemIndices,
  required bool deleteAlbumFiles,
  HistoryDb? database,
  GalleryLocatorService? locator,
  Future<MediaDeleteOutcome> Function(List<MediaRef> media)? deleteMedia,
}) async {
  final id = record.id;
  if (id == null || itemIndices.isEmpty) {
    return const BatchItemDeletionOutcome(ok: false);
  }

  return HistoryDb.withPostLock(id, () async {
    final allRows = <HistoryFile>[];
    for (final idx in itemIndices) {
      allRows.addAll(historyRowsForItem(record, idx));
    }
    if (allRows.isEmpty) return const BatchItemDeletionOutcome(ok: false);

    MediaDeleteOutcome? album;
    String? problem;
    if (deleteAlbumFiles) {
      final refs = deletableRefs(allRows);
      if (refs.isNotEmpty) {
        final call = deleteMedia ?? MediaDeleteService.instance.deleteMedia;
        album = await call(refs);
        if (!album.approved) {
          // User cancelled system deletion dialog
          return const BatchItemDeletionOutcome(ok: false, cancelled: true);
        }
        if (!album.deletedAll) {
          problem = album.problem ?? '部分相册文件未删除';
        }
      }
    }

    final before = record.files;
    final target = allRows.map((r) => '${r.itemIndex}_${r.isImage}').toSet();
    final after = [
      for (final file in before)
        target.contains('${file.itemIndex}_${file.isImage}') &&
                isVisibleHistoryFile(file)
            ? file.copyWith(status: FileStatus.deleted)
            : file,
    ];

    final db = database ?? await HistoryDb.instance();
    await db.updateFiles(id, after, source: 'viewer-batch-items-delete');

    final liveCount = pairSavedMedia(allRows).where((e) => e.isLive).length;
    final deletedFiles = album != null ? (album.requested - album.remaining) : 0;
    final failedFiles = album != null ? album.remaining : 0;
    DevLog.write(
      'HIST',
      'viewer-delete post=${record.postId} selectedItems=${itemIndices.length} files=${allRows.length} live=$liveCount deletedFiles=$deletedFiles failedFiles=$failedFiles',
    );

    return BatchItemDeletionOutcome(
      ok: true,
      succeededIndices: itemIndices,
      before: before,
      after: after,
      albumOutcome: album,
      problem: problem,
      deleteAlbumFiles: deleteAlbumFiles,
    );
  });
}

/// Undo of a "仅删除记录". Restores exactly the rows the deletion replaced.
Future<void> undoHistoryItemDelete(
  HistoryDb db,
  int recordId,
  List<HistoryFile> before,
) => db.updateFiles(recordId, before, source: 'viewer-item-delete-undo');

/// Album refs of [files] that can be deleted by id.
@visibleForTesting
List<MediaRef> deletableRefs(List<HistoryFile> files) => [
  for (final file in files)
    if (file.status == FileStatus.found &&
        file.mediaId != null &&
        file.mediaId!.isNotEmpty)
      MediaRef(mediaId: file.mediaId!, isImage: file.isImage),
];
