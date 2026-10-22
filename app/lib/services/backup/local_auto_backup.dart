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
    final tmpFile = File('${file.path}.tmp');
    await tmpFile.writeAsString(jsonContent, flush: true);
    try {
      await tmpFile.rename(file.path);
    } on FileSystemException {
      if (await file.exists()) {
        await file.delete();
      }
      await tmpFile.rename(file.path);
    }
    _lastBackupTimestampMs = currentTime.millisecondsSinceEpoch;
    try {
      currentSettings.lastBackupTime = currentTime.millisecondsSinceEpoch;
      await currentSettings.save();
    } catch (_) {
      // Best effort saving lastBackupTime
    }
    return true;
  }
}
