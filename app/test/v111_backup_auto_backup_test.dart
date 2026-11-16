// Copyright 2026 EasySave. All rights reserved.
// v1.11 batch 1: restoring the automatic folder backup settings.
//
// A backup carries the auto-backup switch and the folder's display name, never
// the SAF tree URI. Restoring asks the user before switching the feature back
// on, and only a successful folder pick enables it.

import 'dart:convert';

import 'package:easysave/services/backup/auto_backup_resume.dart';
import 'package:easysave/services/backup/backup_model.dart';
import 'package:easysave/services/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _backupJson({
  required Map<String, dynamic> settings,
}) =>
    {
      'format': 'easysave-backup',
      'schemaVersion': 2,
      'formatVersion': 2,
      'exportedAt': '2026-06-01T10:00:00+08:00',
      'appVersion': '1.11.0',
      'provenanceSpecVersion': '1.0',
      'settings': settings,
      'posts': <Object>[],
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('backup format', () {
    test('a v1.11 backup writes the switch and the folder name, no URI', () {
      final settings = BackupSettings(
        autoFolderBackupEnabled: true,
        autoBackupFolderName: 'EasySave Backup',
      );
      final map = settings.toMap();
      expect(map['autoFolderBackupEnabled'], isTrue);
      expect(map['autoBackupFolderName'], 'EasySave Backup');
      expect(settings.hasAutoBackupFields, isTrue);

      final parsed = BackupSettings.fromMap(map);
      expect(parsed.autoFolderBackupEnabled, isTrue);
      expect(parsed.autoBackupFolderName, 'EasySave Backup');

      // The grant itself must never reach the file.
      final json = jsonEncode(map);
      expect(json.contains('content://'), isFalse);
      expect(json.contains('treeUri'), isFalse);
    });

    test('an off switch is written as off, not omitted', () {
      final settings = BackupSettings(
        autoFolderBackupEnabled: false,
        autoBackupFolderName: 'EasySave Backup',
      );
      final map = settings.toMap();
      expect(map.containsKey('autoFolderBackupEnabled'), isTrue);
      expect(map['autoFolderBackupEnabled'], isFalse);
    });

    test('an older backup without the fields is read as "unknown"', () {
      final data = BackupData.fromMap(
        _backupJson(settings: {'albumName': 'EasySave'}),
      );
      expect(data.settings.hasAutoBackupFields, isFalse);
      expect(data.settings.autoFolderBackupEnabled, isNull);
      expect(data.settings.autoBackupFolderName, isNull);
    });

    test('a v1.11 backup round-trips through the whole document', () {
      final data = BackupData.fromMap(_backupJson(settings: {
        'albumName': 'EasySave',
        'autoFolderBackupEnabled': true,
        'autoBackupFolderName': 'EasySave Backup',
      }));
      expect(data.settings.autoFolderBackupEnabled, isTrue);
      expect(data.settings.autoBackupFolderName, 'EasySave Backup');
    });
  });

  group('resume offer', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    Future<AppSettings> deviceSettings() => AppSettings.load();

    test('a pre-v1.11 backup asks nothing and changes nothing', () async {
      final settings = await deviceSettings();
      settings.autoFolderBackupEnabled = true;
      await settings.save();

      var asked = 0;
      final result = await AutoBackupResume.offer(
        backupSettings: BackupSettings(),
        settings: settings,
        ask: (_) async {
          asked++;
          return true;
        },
        pickFolder: (_) async => 'content://tree/other',
      );
      expect(asked, 0);
      expect(result.outcome, AutoBackupResumeOutcome.notOffered);
      expect(await deviceSettings().then((s) => s.autoFolderBackupEnabled), isTrue);
    });

    test('a backup with the switch off asks nothing', () async {
      final settings = await deviceSettings();
      var asked = 0;
      final result = await AutoBackupResume.offer(
        backupSettings: BackupSettings(
          autoFolderBackupEnabled: false,
          autoBackupFolderName: 'EasySave Backup',
        ),
        settings: settings,
        ask: (_) async {
          asked++;
          return true;
        },
        pickFolder: (_) async => 'content://tree/other',
      );
      expect(asked, 0);
      expect(result.outcome, AutoBackupResumeOutcome.notOffered);
      expect(settings.autoFolderBackupEnabled, isFalse);
    });

    test('confirm + granted folder switches auto backup on', () async {
      final settings = await deviceSettings();
      String? prompted;
      String? initialUri = 'sentinel';
      final result = await AutoBackupResume.offer(
        backupSettings: BackupSettings(
          autoFolderBackupEnabled: true,
          autoBackupFolderName: 'EasySave Backup',
        ),
        settings: settings,
        ask: (name) async {
          prompted = name;
          return true;
        },
        pickFolder: (uri) async {
          initialUri = uri;
          return 'content://com.android.externalstorage.documents/tree/primary%3ADocuments%2FEasySave';
        },
        displayNameOf: (_) async => 'Documents/EasySave',
      );
      expect(prompted, 'EasySave Backup');
      // No folder configured on this device yet, so the picker starts neutral.
      expect(initialUri, isNull);
      expect(result.outcome, AutoBackupResumeOutcome.resumed);
      expect(result.folderName, 'Documents/EasySave');

      final reloaded = await deviceSettings();
      expect(reloaded.autoFolderBackupEnabled, isTrue);
      expect(reloaded.backupTreeUri, contains('EasySave'));
      expect(reloaded.backupFolderName, 'Documents/EasySave');
    });

    test('confirm re-opens the picker on the folder already configured',
        () async {
      final settings = await deviceSettings();
      settings.backupTreeUri =
          'content://com.android.externalstorage.documents/tree/primary%3ADocuments%2FEasySave';
      await settings.save();

      String? initialUri;
      await AutoBackupResume.offer(
        backupSettings: BackupSettings(
          autoFolderBackupEnabled: true,
          autoBackupFolderName: 'EasySave Backup',
        ),
        settings: settings,
        ask: (_) async => true,
        pickFolder: (uri) async {
          initialUri = uri;
          return settings.backupTreeUri;
        },
      );
      expect(initialUri, settings.backupTreeUri);
    });

    test('cancel keeps auto backup off', () async {
      final settings = await deviceSettings();
      settings.autoFolderBackupEnabled = true;
      await settings.save();

      var picked = 0;
      final result = await AutoBackupResume.offer(
        backupSettings: BackupSettings(
          autoFolderBackupEnabled: true,
          autoBackupFolderName: 'EasySave Backup',
        ),
        settings: settings,
        ask: (_) async => false,
        pickFolder: (_) async {
          picked++;
          return 'content://tree/never';
        },
      );
      expect(picked, 0, reason: 'a declined prompt never opens the picker');
      expect(result.outcome, AutoBackupResumeOutcome.declined);
      expect((await deviceSettings()).autoFolderBackupEnabled, isFalse);
    });

    test('a cancelled picker keeps auto backup off', () async {
      final settings = await deviceSettings();
      final result = await AutoBackupResume.offer(
        backupSettings: BackupSettings(
          autoFolderBackupEnabled: true,
          autoBackupFolderName: 'EasySave Backup',
        ),
        settings: settings,
        ask: (_) async => true,
        pickFolder: (_) async => null,
      );
      expect(result.outcome, AutoBackupResumeOutcome.grantFailed);
      expect((await deviceSettings()).autoFolderBackupEnabled, isFalse);
      expect((await deviceSettings()).backupTreeUri, isNull);
    });

    test('a picker that throws is treated as a grant failure', () async {
      final settings = await deviceSettings();
      final result = await AutoBackupResume.offer(
        backupSettings: BackupSettings(
          autoFolderBackupEnabled: true,
          autoBackupFolderName: 'EasySave Backup',
        ),
        settings: settings,
        ask: (_) async => true,
        pickFolder: (_) async => throw StateError('permission denied'),
      );
      expect(result.outcome, AutoBackupResumeOutcome.grantFailed);
      expect(settings.autoFolderBackupEnabled, isFalse);
    });

    test('a backup without a folder name still reads naturally', () async {
      final settings = await deviceSettings();
      String? prompted;
      await AutoBackupResume.offer(
        backupSettings: BackupSettings(autoFolderBackupEnabled: true),
        settings: settings,
        ask: (name) async {
          prompted = name;
          return false;
        },
        pickFolder: (_) async => null,
      );
      expect(prompted, AutoBackupResume.fallbackFolderName);
    });
  });
}
