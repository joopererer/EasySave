import 'package:easysave/services/backup/backup_folder_guard.dart';
import 'package:easysave/services/backup/saf_service.dart';
import 'package:easysave/services/settings.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// v1.10.1 build 40: the external backup folder must survive an app update.
//
//   * the grant is persisted when the folder is chosen;
//   * a folder is only "lost" when the system confirms the persisted grant is
//     gone — an unanswered probe never closes the switch;
//   * a lost grant keeps the switch and the folder name and asks for a
//     re-authorisation of the same directory.

const _channelName = 'easysave/saf';
const _treeUri =
    'content://com.android.externalstorage.documents/tree/primary%3ADocuments%2FEasySave';
const _authority = 'com.android.externalstorage.documents';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final channel = const MethodChannel(_channelName);
  late List<MethodCall> calls;
  late List<String> logs;

  void answerGrant(Map<String, Object?> answer) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'checkFolderGrant') return answer;
      if (call.method == 'checkDirectoryAccess') return answer['state'] == 'ok';
      if (call.method == 'pickDirectory') return _treeUri;
      return null;
    });
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    calls = <MethodCall>[];
    logs = <String>[];
    debugPrint = (message, {wrapWidth}) => logs.add(message ?? '');
    BackupFolderGuard.instance.resetForTesting();
    answerGrant({
      'state': 'ok',
      'reason': 'ok',
      'grants': 1,
      'matched': true,
      'exists': true,
      'writable': true,
      'authority': _authority,
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    debugPrint = debugPrintThrottled;
    BackupFolderGuard.instance.resetForTesting();
  });

  Future<AppSettings> configured() async {
    final settings = await AppSettings.load();
    settings.backupTreeUri = _treeUri;
    settings.autoFolderBackupEnabled = true;
    await settings.save();
    return settings;
  }

  test('a full-object save never removes the chosen folder', () async {
    await configured();

    // A snapshot taken before the folder existed (startup backup, bubble sync,
    // restore) must not erase it.
    final stale = AppSettings();
    stale.backgroundToast = false;
    await stale.save();

    final reloaded = await AppSettings.load();
    expect(reloaded.backupTreeUri, _treeUri);
    expect(reloaded.autoFolderBackupEnabled, isTrue);
    expect(reloaded.backgroundToast, isFalse);
  });

  test('only an explicit clear forgets the folder', () async {
    final settings = await configured();
    await settings.clearBackupFolder();
    final reloaded = await AppSettings.load();
    expect(reloaded.backupTreeUri, isNull);
    expect(reloaded.autoFolderBackupEnabled, isFalse);
  });

  test('a present grant keeps everything untouched', () async {
    await configured();
    final state = await BackupFolderGuard.instance.refresh(source: 'test');
    expect(state, FolderAccessState.ok);
    expect(BackupFolderGuard.instance.needsReauth, isFalse);

    final reloaded = await AppSettings.load();
    expect(reloaded.backupTreeUri, _treeUri);
    expect(reloaded.autoFolderBackupEnabled, isTrue);

    final line = logs.firstWhere((l) => l.contains('event=folder_check'));
    expect(line, contains('enabled=true'));
    expect(line, contains('uriPresent=1'));
    expect(line, contains('persistedGrants=1'));
    expect(line, contains('matched=true'));
    expect(line, contains('result=ok'));
    expect(line, contains('provider=externalstorage'));
    expect(line, isNot(contains('content://')));
    expect(line, isNot(contains('/Documents')));
  });

  test('a lost grant asks for re-authorisation instead of closing the switch',
      () async {
    await configured();
    answerGrant({
      'state': 'lost',
      'reason': 'grant_missing',
      'grants': 0,
      'matched': false,
      'exists': false,
      'writable': false,
      'authority': _authority,
    });

    final state = await BackupFolderGuard.instance.refresh(source: 'test');
    expect(state, FolderAccessState.lost);
    expect(BackupFolderGuard.instance.needsReauth, isTrue);
    expect(BackupFolderGuard.instance.pausedBecauseLost, isTrue);

    // The setting is kept: switch on, folder name still there.
    final reloaded = await AppSettings.load();
    expect(reloaded.autoFolderBackupEnabled, isTrue);
    expect(reloaded.backupTreeUri, _treeUri);

    final line = logs.firstWhere((l) => l.contains('event=folder_check'));
    expect(line, contains('result=lost'));
    expect(line, contains('reason=grant_missing'));
    expect(line, contains('matched=false'));
    expect(line, isNot(contains('content://')));
  });

  test('an unanswered probe is never treated as a lost grant', () async {
    await configured();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      throw PlatformException(code: 'FOREGROUND_REQUIRED');
    });

    final state = await BackupFolderGuard.instance.refresh(source: 'test');
    expect(state, FolderAccessState.unknown);
    expect(BackupFolderGuard.instance.needsReauth, isFalse);
    final reloaded = await AppSettings.load();
    expect(reloaded.backupTreeUri, _treeUri);
    expect(reloaded.autoFolderBackupEnabled, isTrue);
  });

  test('an engine without the detailed probe never loses the folder', () async {
    await configured();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      throw MissingPluginException('no easysave/saf');
    });
    final access = await SafService.folderAccess(_treeUri);
    expect(access.state, FolderAccessState.unknown);

    // The settings stay untouched: a channel that cannot answer never closes
    // the switch or forgets the folder.
    await BackupFolderGuard.instance.refresh(source: 'test');
    expect(BackupFolderGuard.instance.needsReauth, isFalse);
    final reloaded = await AppSettings.load();
    expect(reloaded.backupTreeUri, _treeUri);
    expect(reloaded.autoFolderBackupEnabled, isTrue);
  });

  test('re-authorising opens the picker on the configured folder', () async {
    await configured();
    final picked = await SafService.pickDirectory(initialUri: _treeUri);
    expect(picked, _treeUri);
    final call = calls.firstWhere((c) => c.method == 'pickDirectory');
    expect((call.arguments as Map)['initialUri'], _treeUri);
    final line = logs.firstWhere((l) => l.contains('event=folder_pick'));
    expect(line, contains('uriPresent=1'));
    expect(line, contains('provider=externalstorage'));
    expect(line, isNot(contains('content://')));
  });
}
