import 'download_manager.dart';
import 'history_db.dart';

/// Shared by single/bulk deletion, with or without album file deletion.
Future<void> deleteHistoryRecords(
  HistoryDb db,
  Iterable<HistoryRecord> records,
) async {
  for (final record in records) {
    if (record.id == null) continue;
    await db.delete(record.id!);
    await DownloadManager.instance.clearTerminalBatchesForPost(record.postId);
  }
}
