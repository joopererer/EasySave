import 'download_manager.dart';
import 'history_db.dart';
import 'history_io.dart';

/// Records a page must not show after a delete.
///
/// Matching by id is not enough: a snapshot read that was already in flight
/// when the delete committed returns the row again, and a record written by the
/// other engine can carry a different row id for the same post. Build 46 left
/// one of two deleted posts on the history page — still openable — until the
/// page was left and rebuilt.
List<HistoryRecord> dropDeletedRecords(
  Iterable<HistoryRecord> records, {
  Set<int> ids = const {},
  Set<String> postKeys = const {},
}) => [
  for (final record in records)
    if (!(record.id != null && ids.contains(record.id)) &&
        !postKeys.contains('${record.platform}:${record.postId}'))
      record,
];

/// `platform:postId` of [record], the key that survives a row-id change.
String postKeyOf(HistoryRecord record) =>
    '${record.platform}:${record.postId}';

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
