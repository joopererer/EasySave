import 'download_manager.dart';
import 'history_db.dart';
import 'history_io.dart';

/// Shared by single/bulk deletion, with or without album file deletion.
Future<void> deleteHistoryRecords(
  HistoryDb db,
  Iterable<HistoryRecord> records, {
  Future<void> Function(HistoryRecord)? cancelDownloads,
  Future<void> Function(HistoryRecord)? clearQueue,
  Duration maintenanceTimeout = const Duration(seconds: 2),
}) async {
  for (final record in records) {
    if (record.id == null) continue;
    final manager = DownloadManager.instance;
    manager.markPostDeletion(record.platform, record.postId);
    // Send cancellation before deleting, without waiting for another engine.
    // The DB transaction's barrier protects against every late callback.
    final cancellation = historyBackground(
      'delete-cancel',
      () => cancelDownloads != null
          ? cancelDownloads(record)
          : manager.cancelPostDownloads(record.platform, record.postId),
      timeout: maintenanceTimeout,
    );
    await historyStep(
      'delete-db',
      () => db.delete(record.id!),
      timeout: const Duration(seconds: 8),
    );
    historyBackground('delete-queue', () async {
      await cancellation;
      await (clearQueue != null
          ? clearQueue(record)
          : manager.clearTerminalBatchesForPost(record.postId));
    }, timeout: maintenanceTimeout + maintenanceTimeout);
  }
}
