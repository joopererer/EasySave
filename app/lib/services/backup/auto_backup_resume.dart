// Copyright 2026 EasySave. All rights reserved.
// v1.11 batch 1: offer to resume automatic folder backup after a restore.
//
// A backup records the auto-backup switch and the folder's display name, never
// the SAF tree URI: the permission grant belongs to the device that granted it
// and cannot travel in a JSON file. After a restore the user is therefore
// asked whether to keep backing up to that folder; the folder picker then
// re-creates the grant, and only a successful pick switches the feature on.

import '../settings.dart';
import 'backup_model.dart';

/// What happened when the restore flow offered to resume auto backup.
enum AutoBackupResumeOutcome {
  /// The backup carries no auto-backup fields (a pre-v1.11 file) or it says
  /// the feature was off: nothing is asked and nothing is changed.
  notOffered,

  /// The user said no (or dismissed the prompt): auto backup stays off.
  declined,

  /// The user confirmed and the folder was re-authorised: auto backup is on.
  resumed,

  /// The user confirmed but the picker was cancelled or the grant failed:
  /// auto backup stays off.
  grantFailed,
}

/// Result of [AutoBackupResume.offer].
class AutoBackupResumeResult {
  const AutoBackupResumeResult(this.outcome, {this.folderName});

  final AutoBackupResumeOutcome outcome;

  /// Folder name shown in the prompt (the backup's display name, or the
  /// fallback used when the backup carried none).
  final String? folderName;

  bool get asked => outcome != AutoBackupResumeOutcome.notOffered;
}

abstract final class AutoBackupResume {
  /// Folder name used when a backup enabled auto backup but carried no name.
  static const fallbackFolderName = '备份文件夹';

  /// Offers to resume auto backup, if the backup asks for it.
  ///
  /// [ask] shows the confirmation prompt and returns true when the user wants
  /// to continue. [pickFolder] opens the system folder picker and returns the
  /// persisted tree URI, or null when it was cancelled or the grant failed.
  /// [displayNameOf] resolves the picked folder's display name for the
  /// settings; a null answer falls back to the backup's name.
  ///
  /// Nothing here writes a tree URI the system did not grant.
  static Future<AutoBackupResumeResult> offer({
    required BackupSettings? backupSettings,
    required AppSettings settings,
    required Future<bool> Function(String folderName) ask,
    required Future<String?> Function(String? initialUri) pickFolder,
    Future<String?> Function(String treeUri)? displayNameOf,
  }) async {
    if (backupSettings == null || backupSettings.autoFolderBackupEnabled != true) {
      return const AutoBackupResumeResult(AutoBackupResumeOutcome.notOffered);
    }

    final name = (backupSettings.autoBackupFolderName ?? '').trim().isEmpty
        ? fallbackFolderName
        : backupSettings.autoBackupFolderName!.trim();

    final confirmed = await ask(name);
    if (!confirmed) {
      settings.autoFolderBackupEnabled = false;
      await settings.save();
      return AutoBackupResumeResult(
        AutoBackupResumeOutcome.declined,
        folderName: name,
      );
    }

    // Re-open the picker on the folder that is still configured on this
    // device (the backup itself never carries the URI).
    final initialUri =
        (settings.backupTreeUri ?? '').trim().isEmpty ? null : settings.backupTreeUri;
    String? picked;
    try {
      picked = await pickFolder(initialUri);
    } catch (_) {
      picked = null;
    }
    if (picked == null || picked.trim().isEmpty) {
      settings.autoFolderBackupEnabled = false;
      await settings.save();
      return AutoBackupResumeResult(
        AutoBackupResumeOutcome.grantFailed,
        folderName: name,
      );
    }

    settings.backupTreeUri = picked;
    final resolved = await displayNameOf?.call(picked);
    settings.backupFolderName =
        (resolved == null || resolved.trim().isEmpty) ? name : resolved.trim();
    settings.autoFolderBackupEnabled = true;
    settings.backupFolderHintDismissed = true;
    await settings.save();
    return AutoBackupResumeResult(
      AutoBackupResumeOutcome.resumed,
      folderName: settings.backupFolderName,
    );
  }
}
