// Copyright 2026 EasySave. All rights reserved.
// Cold start backup check and decision coordinator.

import 'dart:io';

import '../history_db.dart';
import '../settings.dart';
import 'local_auto_backup.dart';

enum StartupRestoreDecision {
  /// History is empty and a private backup exists in application support files.
  /// Cold-start auto backup MUST NOT run. UI should prompt user to restore.
  promptRestore,

  /// History is empty and no private backup exists.
  /// Cold-start auto backup skipped due to empty history protection.
  emptyHistoryNoBackup,

  /// History is not empty, and cold-start auto backup was executed.
  executedAutoBackup,

  /// History is not empty, but cold-start auto backup was skipped (< 24h since last backup).
  skippedThrottle,
}

class StartupBackupResult {
  final StartupRestoreDecision decision;
  final bool autoBackupExecuted;
  final File? backupFile;

  const StartupBackupResult({
    required this.decision,
    required this.autoBackupExecuted,
    this.backupFile,
  });

  bool get shouldPromptRestore =>
      decision == StartupRestoreDecision.promptRestore;
}

abstract final class StartupBackupCoordinator {
  static const coldStartInterval = Duration(hours: 24);

  /// Pending restore prompt flag that UI can check.
  static bool hasPendingRestorePrompt = false;
  static File? pendingBackupFile;

  /// Pure decision and execution function that can be unit tested.
  static Future<StartupBackupResult> evaluateAndRunStartupBackup({
    HistoryDb? db,
    AppSettings? settings,
    Future<File> Function()? getBackupFileOverride,
    String? customSupportDirPath,
    DateTime? now,
    bool skipAutoBackupExecution = false,
  }) async {
    final store = db ?? await HistoryDb.instance();
    final activeCount = await store.countActive();
    final backupFile = getBackupFileOverride != null
        ? await getBackupFileOverride()
        : await LocalAutoBackup.getBackupFile(
            customSupportDirPath: customSupportDirPath,
          );
    final backupExists = await backupFile.exists();

    // 1. Mandatory First Step (§4.3): Check if history is empty and private backup exists.
    if (activeCount == 0) {
      if (backupExists) {
        hasPendingRestorePrompt = true;
        pendingBackupFile = backupFile;
        return StartupBackupResult(
          decision: StartupRestoreDecision.promptRestore,
          autoBackupExecuted: false,
          backupFile: backupFile,
        );
      } else {
        return const StartupBackupResult(
          decision: StartupRestoreDecision.emptyHistoryNoBackup,
          autoBackupExecuted: false,
        );
      }
    }

    // 2. Active count > 0: Check 24h cold-start auto backup schedule.
    final appSettings = settings ?? await AppSettings.load();
    final currentTime = now ?? DateTime.now();

    bool shouldRunAutoBackup = false;
    if (appSettings.lastBackupTime == null) {
      shouldRunAutoBackup = true;
    } else {
      final lastBackup =
          DateTime.fromMillisecondsSinceEpoch(appSettings.lastBackupTime!);
      final elapsed = currentTime.difference(lastBackup);
      if (elapsed >= coldStartInterval) {
        shouldRunAutoBackup = true;
      }
    }

    if (!shouldRunAutoBackup) {
      return const StartupBackupResult(
        decision: StartupRestoreDecision.skippedThrottle,
        autoBackupExecuted: false,
      );
    }

    if (skipAutoBackupExecution) {
      return const StartupBackupResult(
        decision: StartupRestoreDecision.executedAutoBackup,
        autoBackupExecuted: true,
      );
    }

    final executed = await LocalAutoBackup.performAutoBackup(
      db: store,
      settings: appSettings,
      force: true, // Cold start passed the 24h interval check
      customSupportDirPath: customSupportDirPath,
      now: currentTime,
    );

    return StartupBackupResult(
      decision: executed
          ? StartupRestoreDecision.executedAutoBackup
          : StartupRestoreDecision.skippedThrottle,
      autoBackupExecuted: executed,
      backupFile: backupFile,
    );
  }
}
