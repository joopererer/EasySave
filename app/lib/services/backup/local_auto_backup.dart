// Copyright 2026 EasySave. All rights reserved.
// Tier 2 Android Auto Backup file writer and scheduler with empty history protection.

import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../history_db.dart';
import '../settings.dart';
import 'backup_service.dart';

abstract final class LocalAutoBackup {
  static const throttleDuration = Duration(hours: 1);
  static int? _lastBackupTimestampMs;

  /// Serialises the backups of this process.
  ///
  /// Two batches can finish at the same moment (the download manager starts one
  /// unawaited auto backup per finished batch), and both used to write the same
  /// `<dir>/backup/easysave-backup.json.tmp` and then rename it. On Windows the
  /// second rename found the file still open and failed with
  /// `Cannot rename …backup.json.tmp`; on Android the same race would simply
  /// lose one of the two writes. One backup at a time, each with its own temp
  /// name, makes that impossible.
  static Future<void> _tail = Future<void>.value();

  /// Resets throttling state (for unit testing).
  static void resetThrottleForTest() {
    _lastBackupTimestampMs = null;
  }

  /// Path to the private backup file inside application support files.
  static Future<File> getBackupFile({String? customSupportDirPath}) async {
    final basePath =
        customSupportDirPath ?? (await getApplicationSupportDirectory()).path;
    final backupDir = Directory('$basePath/backup');
    if (!backupDir.existsSync()) {
      backupDir.createSync(recursive: true);
    }
    return File('${backupDir.path}/easysave-backup.json');
  }

  /// Check if a private backup file exists.
  static Future<bool> hasPrivateBackup({String? customSupportDirPath}) async {
    try {
      final file = await getBackupFile(customSupportDirPath: customSupportDirPath);
      return await file.exists();
    } catch (_) {
      return false;
    }
  }

  /// Perform automatic backup to private directory.
  /// Returns true if backup was written, false if skipped (e.g. empty history or throttled).
  static Future<bool> performAutoBackup({
    HistoryDb? db,
    AppSettings? settings,
    bool force = false,
    String? customSupportDirPath,
    DateTime? now,
  }) {
    // One at a time: a second caller waits for the first to finish instead of
    // writing the same temp file (see [_tail]).
    final next = _tail.then(
      (_) => _performAutoBackup(
        db: db,
        settings: settings,
        force: force,
        customSupportDirPath: customSupportDirPath,
        now: now,
      ),
    );
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  static Future<bool> _performAutoBackup({
    HistoryDb? db,
    AppSettings? settings,
    bool force = false,
    String? customSupportDirPath,
    DateTime? now,
  }) async {
    final store = db ?? await HistoryDb.instance();
    if (await BackupService.isHistoryEmpty(db: store)) {
      // Empty history protection (§4.3): never write or overwrite auto backup
      // if active history is empty, preserving existing backups recovered by OS.
      return false;
    }

    final currentTime = now ?? DateTime.now();
    if (!force && _lastBackupTimestampMs != null) {
      final elapsed = currentTime.difference(
        DateTime.fromMillisecondsSinceEpoch(_lastBackupTimestampMs!),
      );
      if (elapsed < throttleDuration) {
        return false;
      }
    }

    final currentSettings = settings ?? await AppSettings.load();
    final jsonContent = await BackupService.exportBackup(
      db: store,
      settings: currentSettings,
      now: currentTime,
    );

    final file = await getBackupFile(customSupportDirPath: customSupportDirPath);
    // A temp name of this write only: even a second writer of the same target
    // (another process, a test that shares the directory) can never collide
    // with this one.
    final tmpFile = File(
      '${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    await tmpFile.writeAsString(jsonContent, flush: true);
    await _replaceFile(tmpFile, file);
    _lastBackupTimestampMs = currentTime.millisecondsSinceEpoch;
    try {
      currentSettings.lastBackupTime = currentTime.millisecondsSinceEpoch;
      await currentSettings.save();
    } catch (_) {
      // Best effort saving lastBackupTime
    }
    return true;
  }

  /// Moves [tmp] onto [target], retrying the rename.
  ///
  /// Windows refuses a rename while the target is open in another handle (a
  /// virus scanner, another isolate, the previous writer): a short retry
  /// ladder turns that into a successful write instead of an exception that
  /// loses the whole backup.
  static Future<void> _replaceFile(File tmp, File target) async {
    const waits = [
      Duration(milliseconds: 10),
      Duration(milliseconds: 40),
      Duration(milliseconds: 120),
      Duration(milliseconds: 300),
    ];
    for (var attempt = 0; ; attempt++) {
      try {
        await tmp.rename(target.path);
        return;
      } on FileSystemException {
        if (attempt >= waits.length) rethrow;
        if (await target.exists()) {
          try {
            await target.delete();
          } on FileSystemException {
            // Still held: the retry below waits for it.
          }
        }
        await Future<void>.delayed(waits[attempt]);
      }
    }
  }
}
