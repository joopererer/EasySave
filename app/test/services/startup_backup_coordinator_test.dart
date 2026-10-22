// Copyright 2026 EasySave. All rights reserved.
// Tests for Step 3: StartupBackupCoordinator, XML rules, and AndroidManifest backup configuration.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:easysave/services/backup/startup_backup_coordinator.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/settings.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Step 3: Android Auto Backup Configuration Validation', () {
    test('data_extraction_rules.xml contains required cloud-backup and device-transfer rules', () {
      final projectRoot = Directory.current.path.endsWith('app')
          ? Directory.current.path
          : '${Directory.current.path}/app';
      final file = File('$projectRoot/android/app/src/main/res/xml/data_extraction_rules.xml');
      expect(file.existsSync(), isTrue);

      final content = file.readAsStringSync();
      expect(content.contains('<data-extraction-rules>'), isTrue);
      expect(content.contains('<cloud-backup>'), isTrue);
      expect(content.contains('<device-transfer>'), isTrue);
      expect(content.contains('<include domain="file" path="backup/easysave-backup.json" />'), isTrue);
      expect(content.contains('<exclude domain="database" path="." />'), isTrue);
      expect(content.contains('<exclude domain="sharedpref" path="." />'), isTrue);
    });

    test('backup_rules.xml contains required full-backup-content rules', () {
      final projectRoot = Directory.current.path.endsWith('app')
          ? Directory.current.path
          : '${Directory.current.path}/app';
      final file = File('$projectRoot/android/app/src/main/res/xml/backup_rules.xml');
      expect(file.existsSync(), isTrue);

      final content = file.readAsStringSync();
      expect(content.contains('<full-backup-content>'), isTrue);
      expect(content.contains('<include domain="file" path="backup/easysave-backup.json" />'), isTrue);
      expect(content.contains('<exclude domain="database" path="." />'), isTrue);
      expect(content.contains('<exclude domain="sharedpref" path="." />'), isTrue);
    });

    test('AndroidManifest.xml specifies allowBackup and backup rule XML files', () {
      final projectRoot = Directory.current.path.endsWith('app')
          ? Directory.current.path
          : '${Directory.current.path}/app';
      final file = File('$projectRoot/android/app/src/main/AndroidManifest.xml');
      expect(file.existsSync(), isTrue);

      final content = file.readAsStringSync();
      expect(content.contains('android:allowBackup="true"'), isTrue);
      expect(content.contains('android:dataExtractionRules="@xml/data_extraction_rules"'), isTrue);
      expect(content.contains('android:fullBackupContent="@xml/backup_rules"'), isTrue);
    });
  });

  group('Step 3: Startup Backup Decision & Empty History Protection', () {
    late Directory tempDir;
    late HistoryDb db;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('startup_backup_test_');
      final dbPath = '${tempDir.path}/test_history.db';
      db = await HistoryDb.instance(dbPath: dbPath);
      await db.clear();
    });

    tearDown(() async {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    });

    test('history empty and private backup exists: does NOT run auto-backup and does NOT overwrite file', () async {
      final backupDir = Directory('${tempDir.path}/backup')..createSync(recursive: true);
      final privateBackupFile = File('${backupDir.path}/easysave-backup.json');
      const existingBackupContent = '{"format":"easysave-backup","formatVersion":1,"testData":"do_not_overwrite"}';
      await privateBackupFile.writeAsString(existingBackupContent);

      final settings = AppSettings();
      final result = await StartupBackupCoordinator.evaluateAndRunStartupBackup(
        db: db,
        settings: settings,
        customSupportDirPath: tempDir.path,
        now: DateTime(2026, 10, 22, 10, 0),
      );

      // Must signal restore prompt
      expect(result.shouldPromptRestore, isTrue);
      expect(result.decision, StartupRestoreDecision.promptRestore);
      expect(result.autoBackupExecuted, isFalse);

      // Verify the private backup file was untouched and retains original content
      expect(privateBackupFile.existsSync(), isTrue);
      expect(await privateBackupFile.readAsString(), existingBackupContent);
    });

    test('history empty and NO private backup: does NOT run auto-backup', () async {
      final settings = AppSettings();
      final result = await StartupBackupCoordinator.evaluateAndRunStartupBackup(
        db: db,
        settings: settings,
        customSupportDirPath: tempDir.path,
        now: DateTime(2026, 10, 22, 10, 0),
      );

      expect(result.shouldPromptRestore, isFalse);
      expect(result.decision, StartupRestoreDecision.emptyHistoryNoBackup);
      expect(result.autoBackupExecuted, isFalse);

      final privateBackupFile = File('${tempDir.path}/backup/easysave-backup.json');
      expect(privateBackupFile.existsSync(), isFalse);
    });

    test('history not empty and lastBackupTime is null: runs cold-start auto backup', () async {
      // Insert one active record
      await db.upsert(
        HistoryRecord(
          platform: 'xhs',
          postId: 'active_123',
          postUrl: 'https://example.com/item',
          title: 'Active Post',
          fileCount: 0,
          createdAt: DateTime.now(),
          files: [],
        ),
      );

      final settings = AppSettings();
      expect(settings.lastBackupTime, isNull);

      final coldStartTime = DateTime(2026, 10, 22, 12, 0);
      final result = await StartupBackupCoordinator.evaluateAndRunStartupBackup(
        db: db,
        settings: settings,
        customSupportDirPath: tempDir.path,
        now: coldStartTime,
      );

      expect(result.shouldPromptRestore, isFalse);
      expect(result.decision, StartupRestoreDecision.executedAutoBackup);
      expect(result.autoBackupExecuted, isTrue);

      final privateBackupFile = File('${tempDir.path}/backup/easysave-backup.json');
      expect(privateBackupFile.existsSync(), isTrue);
      final parsed = jsonDecode(await privateBackupFile.readAsString()) as Map<String, dynamic>;
      expect(parsed['format'], 'easysave-backup');
      expect((parsed['posts'] as List).length, 1);
      expect(settings.lastBackupTime, coldStartTime.millisecondsSinceEpoch);
    });

    test('history not empty and elapsed < 24h: skips cold-start auto backup', () async {
      await db.upsert(
        HistoryRecord(
          platform: 'xhs',
          postId: 'active_456',
          postUrl: 'https://example.com/item2',
          title: 'Active Post 2',
          fileCount: 0,
          createdAt: DateTime.now(),
          files: [],
        ),
      );

      final lastBackup = DateTime(2026, 10, 22, 8, 0);
      final settings = AppSettings()..lastBackupTime = lastBackup.millisecondsSinceEpoch;

      // Only 3 hours later
      final coldStartTime = DateTime(2026, 10, 22, 11, 0);
      final result = await StartupBackupCoordinator.evaluateAndRunStartupBackup(
        db: db,
        settings: settings,
        customSupportDirPath: tempDir.path,
        now: coldStartTime,
      );

      expect(result.shouldPromptRestore, isFalse);
      expect(result.decision, StartupRestoreDecision.skippedThrottle);
      expect(result.autoBackupExecuted, isFalse);
    });

    test('history not empty and elapsed >= 24h: runs cold-start auto backup', () async {
      await db.upsert(
        HistoryRecord(
          platform: 'xhs',
          postId: 'active_789',
          postUrl: 'https://example.com/item3',
          title: 'Active Post 3',
          fileCount: 0,
          createdAt: DateTime.now(),
          files: [],
        ),
      );

      final lastBackup = DateTime(2026, 10, 21, 10, 0);
      final settings = AppSettings()..lastBackupTime = lastBackup.millisecondsSinceEpoch;

      // 25 hours later
      final coldStartTime = DateTime(2026, 10, 22, 11, 0);
      final result = await StartupBackupCoordinator.evaluateAndRunStartupBackup(
        db: db,
        settings: settings,
        customSupportDirPath: tempDir.path,
        now: coldStartTime,
      );

      expect(result.shouldPromptRestore, isFalse);
      expect(result.decision, StartupRestoreDecision.executedAutoBackup);
      expect(result.autoBackupExecuted, isTrue);
      expect(settings.lastBackupTime, coldStartTime.millisecondsSinceEpoch);
    });
  });
}
