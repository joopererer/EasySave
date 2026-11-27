// Shared browser flows for a stored post (v1.11 batch 4).
//
// The history tab and the "最近保存" list both open the same viewer, so the
// re-download of an item that is not on this device any more lives here: parse
// the original post again, open the preview selection with exactly those items
// ticked, then report the refreshed viewer items so the page updates in place.

import 'package:flutter/material.dart';

import '../core/models.dart';
import '../pages/preview_page.dart';
import '../services/history_db.dart';
import '../services/history_deletion.dart';
import '../services/history_item_delete.dart';
import '../services/media_delete_service.dart';
import '../services/parse_service.dart';
import 'gallery_browser.dart';

/// User-facing copy for a re-parse that could not deliver the post.
String redownloadFailureMessage(ParseFailure failure) {
  switch (failure.code) {
    case ParseErrorCode.loginRequired:
      return '该内容需要登录后查看，请先登录再重新下载';
    case ParseErrorCode.postNotFound:
    case ParseErrorCode.privateOrUnavailable:
      return '原帖已不可访问（可能已删除），历史记录未改变';
    case ParseErrorCode.mediaUnavailable:
      return '原帖的媒体地址已失效，请重新登录后再试';
    case ParseErrorCode.tokenRequired:
      return '原帖链接的访问凭证已失效，请重新复制分享链接';
    case ParseErrorCode.ageRestricted:
    case ParseErrorCode.ageNotSet:
      return '该内容需要年龄验证后才能查看';
    case ParseErrorCode.protectedAccount:
      return '原帖作者已开启保护，无法重新解析';
    case ParseErrorCode.blocked:
      return '访问受限，暂时无法重新解析';
    case ParseErrorCode.timeout:
      return '重新解析超时，请检查网络后重试';
    default:
      return failure.message.isEmpty ? '重新解析失败，请稍后重试' : failure.message;
  }
}

/// Rebuild the viewer items of [record] from the database.
Future<List<GalleryBrowserItem>> browserItemsForRecord(
  HistoryRecord record,
) async {
  final built = await savedBrowserItems(
    record: record,
    files: record.visibleFiles,
    post: record.toPost(),
  );
  return built.items;
}

/// The record as it stands now (another engine may have written it).
Future<HistoryRecord> reloadRecord(HistoryRecord record) async {
  try {
    final db = await HistoryDb.instance();
    return await db.getByPostId(record.postId, platform: record.platform) ??
        record;
  } catch (_) {
    return record;
  }
}

/// The items of [indices] that still exist in [post].
///
/// A post can lose items between the save and the re-download; nothing outside
/// this set may be preselected, or the user would silently download a different
/// picture than the one they asked for.
Set<int> preselectableIndices(ParsedPost post, Set<int> indices) => {
  for (final index in indices)
    if (index >= 0 && index < post.items.length) index,
};

/// Re-download [indices] (original post item indices) of [record].
///
/// The post is parsed again on purpose: the stored items may be stale (signed
/// URLs expire) and the user must be able to change the selection before the
/// download starts. Nothing about the record is touched unless the user saves.
/// Returns the refreshed viewer items and the post's current total, or null
/// when nothing changed.
Future<GalleryBrowserRefresh?> redownloadRecordItems(
  BuildContext context,
  HistoryRecord record,
  Set<int> indices,
) async {
  if (indices.isEmpty) return null;
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    const SnackBar(content: Text('正在重新解析原帖…'), duration: Duration(seconds: 2)),
  );

  ParsedPost post;
  try {
    final outcome = await parsePostOutcome(
      record.postUrl,
      source: 'history_redownload',
      // The stored URLs are the ones that expired: parse the post again.
      forceRefresh: true,
    );
    post = outcome.data;
  } on ParseFailure catch (e) {
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(redownloadFailureMessage(e))));
    return null;
  } catch (_) {
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      const SnackBar(content: Text('重新解析失败，请稍后重试')),
    );
    return null;
  }

  // The post may have lost items since it was saved: never preselect an index
  // that no longer exists, say which ones are gone, and download the rest.
  final valid = preselectableIndices(post, indices);
  if (valid.isEmpty) {
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      const SnackBar(content: Text('原帖中已找不到这些内容，历史记录未改变')),
    );
    return null;
  }
  final dropped = indices.length - valid.length;
  if (!context.mounted) return null;
  messenger.hideCurrentSnackBar();
  if (dropped > 0) {
    messenger.showSnackBar(
      SnackBar(
        content: Text('原帖中已找不到其中 $dropped 项，只下载还在的 ${valid.length} 项'),
      ),
    );
  }

  await PreviewPage.open(context, post: post, initialSelection: valid);
  if (!context.mounted) return null;

  // The download wrote its own rows, so the fresh record already knows which
  // items are back. No album rescan is needed (and none is added) to show it.
  final fresh = await reloadRecord(record);
  try {
    return GalleryBrowserRefresh(
      items: await browserItemsForRecord(fresh),
      postTotal: fresh.originalItemCount,
    );
  } catch (_) {
    return null;
  }
}

/// Turn the album asset behind one browser item into the refs the delete flow
/// needs. Read-only with respect to the album.
List<HistoryFile> historyFilesForItem(HistoryRecord record, int itemIndex) =>
    historyRowsForItem(record, itemIndex);

/// Delete one item of [record] on behalf of the viewer.
///
/// [onChanged] runs after the write (and after an undo) so the page behind the
/// viewer can refresh its cards. "仅删除记录" returns an undo closure; deleting
/// the album file cannot be undone, exactly like the multi-select delete.
Future<GalleryBrowserItemDeletion?> deleteBrowserItemForRecord(
  HistoryRecord record,
  GalleryBrowserItem item, {
  required bool deleteAlbumFiles,
  void Function()? onChanged,
}) async {
  final fresh = await reloadRecord(record);
  final outcome = await deleteHistoryItem(
    fresh,
    itemIndex: item.index,
    deleteAlbumFiles: deleteAlbumFiles,
  );
  if (!outcome.ok) return const GalleryBrowserItemDeletion(ok: false);
  final id = fresh.id;
  if (outcome.visibleRemaining == 0 && id != null) {
    final db = await HistoryDb.instance();
    await db.delete(id);
  }
  onChanged?.call();
  return GalleryBrowserItemDeletion(
    ok: true,
    message: outcome.problem ??
        (deleteAlbumFiles ? '已删除这张，并删除相册文件' : '已删除这张'),
    undo: deleteAlbumFiles || id == null
        ? null
        : () async {
            final db = await HistoryDb.instance();
            await undoHistoryItemDelete(db, id, outcome.before);
            onChanged?.call();
          },
  );
}

/// Delete multiple items from the open viewer in a single batch.
Future<BatchGalleryBrowserItemDeletion> deleteBrowserItemsForRecord(
  HistoryRecord record,
  List<GalleryBrowserItem> items, {
  required bool deleteAlbumFiles,
  void Function()? onChanged,
  Future<MediaDeleteOutcome> Function(List<MediaRef> media)? deleteMedia,
}) async {
  final fresh = await reloadRecord(record);
  final indices = items.map((i) => i.index).toSet();
  final outcome = await deleteHistoryItems(
    fresh,
    itemIndices: indices,
    deleteAlbumFiles: deleteAlbumFiles,
    deleteMedia: deleteMedia,
  );
  if (outcome.cancelled) {
    return const BatchGalleryBrowserItemDeletion(ok: false, cancelled: true);
  }
  if (!outcome.ok) {
    return const BatchGalleryBrowserItemDeletion(ok: false);
  }
  final id = fresh.id;
  if (outcome.after.where(isVisibleHistoryFile).isEmpty && id != null) {
    final db = await HistoryDb.instance();
    await db.delete(id);
  }
  onChanged?.call();
  return BatchGalleryBrowserItemDeletion(
    ok: true,
    succeededIndices: outcome.succeededIndices,
    failedCount: outcome.failedIndices.length,
    message: outcome.problem,
    undo: deleteAlbumFiles || id == null
        ? null
        : () async {
            final db = await HistoryDb.instance();
            await undoHistoryItemDelete(db, id, outcome.before);
            onChanged?.call();
          },
  );
}

/// Drop the whole record of a post whose every item was deleted in the viewer.
Future<void> deleteRecordForGood(
  HistoryRecord record, {
  Future<void> Function(HistoryRecord fresh)? delete,
}) async {
  final fresh = await reloadRecord(record);
  if (fresh.id == null) return;
  if (delete != null) {
    await delete(fresh);
    return;
  }
  final db = await HistoryDb.instance();
  await deleteHistoryRecords(db, [fresh]);
}
