// Whether the persisted backup folder still authorises writes.
//
// Shared by the backup settings page and the home page so both can show the
// same one-tap "re-authorise" prompt without either of them switching the
// auto-backup toggle off on its own.
//
// Rules:
//   * a folder is only "lost" when the system confirmed the persisted grant is
//     gone (see [FolderAccessState.lost]); an unanswered probe is `unknown`;
//   * a lost folder keeps the switch and the folder name: the user re-authorises
//     the same directory, nothing is silently reset;
//   * every check writes one `[Backup]` log line with the authority type only,
//     never the tree URI, its query or any account data.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/dev_log.dart';import '../settings.dart';
import 'saf_service.dart';

class BackupFolderGuard extends ChangeNotifier {
  BackupFolderGuard._();

  static final BackupFolderGuard instance = BackupFolderGuard._();

  /// State of the last check (default: not checked in this process).
  FolderAccessState state = FolderAccessState.unknown;

  /// Why the last check ended the way it did (`ok`, `grant_missing`, …).
  String reason = 'not_checked';

  /// Auto backup switch as stored in settings (never modified by the guard).
  bool enabled = false;

  /// Whether a folder URI is configured.
  bool uriPresent = false;

  /// Authority type of the configured folder (`externalstorage`), or `-`.
  String authority = '-';

  /// Grants reported by the system during the last check.
  int grants = 0;

  /// Whether one of the persisted grants matched the configured folder.
  bool matched = false;

  /// The folder is configured and the system confirmed its grant is gone.
  bool get needsReauth =>
      uriPresent && state == FolderAccessState.lost;

  /// Auto backup is paused because the folder cannot be written any more.
  bool get pausedBecauseLost => needsReauth && enabled;

  /// Re-reads the settings and probes the folder. Logs one `[Backup]` line.
  Future<FolderAccessState> refresh({String source = 'startup'}) async {
    final settings = await AppSettings.load();
    enabled = settings.autoFolderBackupEnabled;
    final treeUri = settings.backupTreeUri;
    uriPresent = treeUri != null && treeUri.isNotEmpty;
    FolderAccess access;
    if (!uriPresent || treeUri == null) {
      access = const FolderAccess(
        state: FolderAccessState.unknown,
        reason: 'not_configured',
        authority: '-',
      );
    } else {
      access = await SafService.folderAccess(treeUri);
    }
    state = access.state;
    reason = access.reason;
    authority = access.authorityLabel;
    grants = access.grants;
    matched = access.matched;
    unawaited(DevLog.write(
      'Backup', // i18n:ignore 日志
      'event=folder_check source=$source enabled=$enabled '
          'uriPresent=${uriPresent ? 1 : 0} persistedGrants=$grants '
          'matched=$matched result=${access.state.name} reason=$reason '
          // Provider type only (externalstorage for the system picker). DevLog
          // redacts any `auth*` key, so the field is named provider.
          'provider=$authority',
    ));
    notifyListeners();
    return state;
  }

  /// The folder was re-authorised (or replaced): nothing is pending any more.
  void markAuthorised() {
    state = FolderAccessState.ok;
    reason = 'ok';
    notifyListeners();
  }

  @visibleForTesting
  void resetForTesting() {
    state = FolderAccessState.unknown;
    reason = 'not_checked';
    enabled = false;
    uriPresent = false;
    authority = '-';
    grants = 0;
    matched = false;
  }
}
