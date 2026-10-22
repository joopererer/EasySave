// Copyright 2026 EasySave. All rights reserved.
// Tests for Step 4: SafService, rotation pruning rules, empty history protection, and error propagation.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:easysave/services/backup/saf_service.dart';
import 'package:easysave/services/backup/backup_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Step 4: Backup Filename Formatting & Timestamp Extraction', () {
    test('formatBackupFileName formats exactly to easysave-backup-YYYYMMDD-HHmm.json', () {
      final dt = DateTime(2026, 10, 22, 14, 5);
      final filename = formatBackupFileName(dt);
      expect(filename, 'easysave-backup-20261022-1405.json');
      expect(extractBackupTimestamp(filename), '20261022-1405');
    });

    test('extractBackupTimestamp returns null for non-matching files', () {
      expect(extractBackupTimestamp('easysave-backup.json'), isNull);
      expect(extractBackupTimestamp('easysave-backup-2026.json'), isNull);
      expect(extractBackupTimestamp('easysave-backup-20261022.json'), isNull);
      expect(extractBackupTimestamp('easysave-backup-20261022-1405.bak'), isNull);
      expect(extractBackupTimestamp('photo.jpg'), isNull);
      expect(extractBackupTimestamp('notes.txt'), isNull);
      expect(extractBackupTimestamp('my_backup_file.json'), isNull);
      expect(extractBackupTimestamp('easysave-backup-20261022-1405.json.tmp'), isNull);
    });
  });

  group('Step 4: Backup Rotation Pruning Rules', () {
    test('retains top 7 newest backups and ignores all non-matching files', () {
      final fileList = [
        'easysave-backup-20261022-1500.json', // 1 (newest)
        'photo.jpg',                          // Other file
        'easysave-backup-20261022-1400.json', // 2
        'notes.txt',                          // Other file
        'easysave-backup-20261022-1300.json', // 3
        'easysave-backup.json',               // Other file (private backup name)
        'easysave-backup-20261022-1200.json', // 4
        'easysave-backup-20261022-1100.json', // 5
        'random_folder',                      // Other file
        'easysave-backup-20261022-1000.json', // 6
        'easysave-backup-20261022-0900.json', // 7 (boundary: kept)
        'easysave-backup-20261021-2300.json', // 8 (pruned)
        'easysave-backup-20261021-2200.json', // 9 (pruned)
        'easysave-backup-20261020-0800.json', // 10 (pruned)
        'manual-backup.json',                 // Other file
      ];

      final pruneCandidates = getPruneCandidates(fileList, keepCount: 7);

      // Must strictly contain only the 3 older matching backup files
      expect(pruneCandidates, [
        'easysave-backup-20261021-2300.json',
        'easysave-backup-20261021-2200.json',
        'easysave-backup-20261020-0800.json',
      ]);

      // None of the other files may ever be touched
      expect(pruneCandidates.contains('photo.jpg'), isFalse);
      expect(pruneCandidates.contains('notes.txt'), isFalse);
      expect(pruneCandidates.contains('easysave-backup.json'), isFalse);
      expect(pruneCandidates.contains('random_folder'), isFalse);
      expect(pruneCandidates.contains('manual-backup.json'), isFalse);
    });

    test('when matching count is <= 7, prune candidates list is empty', () {
      final fileList = [
        'easysave-backup-20261022-1500.json',
        'easysave-backup-20261022-1400.json',
        'easysave-backup-20261022-1300.json',
        'photo.jpg',
      ];

      final pruneCandidates = getPruneCandidates(fileList, keepCount: 7);
      expect(pruneCandidates, isEmpty);
    });
  });

  group('Step 4: Tier 3 Empty History Protection & Manual Check', () {
    late Directory tempDir;
    late HistoryDb db;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('saf_test_');
      final dbPath = '${tempDir.path}/test_history.db';
      db = await HistoryDb.instance(dbPath: dbPath);
      await db.clear();
      SafService.resetThrottleForTest();
    });

    tearDown(() async {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    });

    test('isHistoryEmpty correctly identifies empty vs non-empty history', () async {
      expect(await BackupService.isHistoryEmpty(db: db), isTrue);

      await db.upsert(
        HistoryRecord(
          platform: 'xhs',
          postId: 'post_100',
          postUrl: 'https://example.com/p',
          title: 'Post 100',
          fileCount: 0,
          createdAt: DateTime.now(),
          files: [],
        ),
      );

      expect(await BackupService.isHistoryEmpty(db: db), isFalse);
    });

    test('performAutoBackupToDirectory: history empty skips auto-backup without writing or deleting', () async {
      var writeCalled = false;
      final channel = MethodChannel('mock_channel');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'writeBackupToDirectory') {
          writeCalled = true;
          return 'content://com.android.externalstorage.documents/document/test.json';
        }
        return null;
      });

      final settings = AppSettings()..backupTreeUri = 'content://tree/test';

      final result = await SafService.performAutoBackupToDirectory(
        db: db,
        settings: settings,
        channelOverride: channel,
      );

      expect(result, isFalse);
      expect(writeCalled, isFalse);
    });

    test('performAutoBackupToDirectory: backupTreeUri not set skips auto-backup', () async {
      final settings = AppSettings()..backupTreeUri = null;

      final result = await SafService.performAutoBackupToDirectory(
        db: db,
        settings: settings,
      );

      expect(result, isFalse);
    });

    test('performAutoBackupToDirectory: active history executes backup, verifies, rotates, and updates lastBackupTime', () async {
      await db.upsert(
        HistoryRecord(
          platform: 'xhs',
          postId: 'post_200',
          postUrl: 'https://example.com/p2',
          title: 'Post 200',
          fileCount: 0,
          createdAt: DateTime.now(),
          files: [],
        ),
      );

      var writtenFileName = '';
      var writtenContent = '';
      var rotated = false;
      final channel = MethodChannel('mock_channel');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'writeBackupToDirectory') {
          writtenFileName = call.arguments['fileName'] as String;
          writtenContent = call.arguments['content'] as String;
          return 'content://uri/$writtenFileName';
        } else if (call.method == 'readDocumentContent') {
          return writtenContent;
        } else if (call.method == 'rotateBackups') {
          rotated = true;
          return 0;
        }
        return null;
      });

      final settings = AppSettings()..backupTreeUri = 'content://tree/target';
      final backupTime = DateTime(2026, 10, 22, 16, 30);

      final result = await SafService.performAutoBackupToDirectory(
        db: db,
        settings: settings,
        now: backupTime,
        channelOverride: channel,
      );

      expect(result, isTrue);
      expect(rotated, isTrue);
      expect(writtenFileName, 'easysave-backup-20261022-1630.json');
      expect(writtenContent.contains('easysave-backup'), isTrue);
      expect(settings.lastBackupTime, backupTime.millisecondsSinceEpoch);
    });

    test('performAutoBackupToDirectory: throttles within 1 hour unless forced', () async {
      await db.upsert(
        HistoryRecord(
          platform: 'xhs',
          postId: 'post_300',
          postUrl: 'https://example.com/p3',
          title: 'Post 300',
          fileCount: 0,
          createdAt: DateTime.now(),
          files: [],
        ),
      );

      int writeCount = 0;
      String lastWritten = '';
      final channel = MethodChannel('mock_channel');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'writeBackupToDirectory') {
          writeCount++;
          lastWritten = call.arguments['content'] as String;
          return 'content://uri/file';
        } else if (call.method == 'readDocumentContent') {
          return lastWritten;
        } else if (call.method == 'rotateBackups') {
          return 0;
        }
        return null;
      });

      final settings = AppSettings()..backupTreeUri = 'content://tree/target';
      final t1 = DateTime(2026, 10, 22, 12, 0);
      final first = await SafService.performAutoBackupToDirectory(
        db: db,
        settings: settings,
        now: t1,
        channelOverride: channel,
      );
      expect(first, isTrue);
      expect(writeCount, 1);

      // 30 minutes later: throttled
      final t2 = DateTime(2026, 10, 22, 12, 30);
      final second = await SafService.performAutoBackupToDirectory(
        db: db,
        settings: settings,
        now: t2,
        channelOverride: channel,
      );
      expect(second, isFalse);
      expect(writeCount, 1);

      // forced: succeeds
      final third = await SafService.performAutoBackupToDirectory(
        db: db,
        settings: settings,
        now: t2,
        force: true,
        channelOverride: channel,
      );
      expect(third, isTrue);
      expect(writeCount, 2);
    });
  });

  group('Step 4: SAF Error Handling & Typed Exceptions', () {
    test('writeBackupToDirectory maps PERMISSION_LOST to SafPermissionException', () async {
      final channel = MethodChannel('mock_err_channel');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'PERMISSION_LOST', message: 'Permission revoked');
      });

      expect(
        () => SafService.writeBackupToDirectory(
          'content://tree',
          'test.json',
          '{}',
          channelOverride: channel,
        ),
        throwsA(isA<SafPermissionException>()),
      );
    });

    test('writeBackupToDirectory maps DIRECTORY_NOT_FOUND to SafDirectoryNotFoundException', () async {
      final channel = MethodChannel('mock_err_channel');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'DIRECTORY_NOT_FOUND', message: 'Dir removed');
      });

      expect(
        () => SafService.writeBackupToDirectory(
          'content://tree',
          'test.json',
          '{}',
          channelOverride: channel,
        ),
        throwsA(isA<SafDirectoryNotFoundException>()),
      );
    });

    test('writeBackupToDirectory maps STORAGE_FULL to SafStorageFullException', () async {
      final channel = MethodChannel('mock_err_channel');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'STORAGE_FULL', message: 'No space left');
      });

      expect(
        () => SafService.writeBackupToDirectory(
          'content://tree',
          'test.json',
          '{}',
          channelOverride: channel,
        ),
        throwsA(isA<SafStorageFullException>()),
      );
    });

    test('readDocumentContent maps IO errors to SafIOException', () async {
      final channel = MethodChannel('mock_err_channel');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'IO_ERROR', message: 'Read failure');
      });

      expect(
        () => SafService.readDocumentContent('content://uri', channelOverride: channel),
        throwsA(isA<SafIOException>()),
      );
    });
  });

  group('2a Correction: Write, Read-back Verification and Rotation Order', () {
    test('writeAndVerifyBackup: verification succeeds and triggers rotation', () async {
      var rotateCalled = false;
      var writeCalled = false;
      const validJson = '{"format":"easysave-backup","formatVersion":1,"exportedAt":"2026-10-22T10:00:00Z","posts":[{"platform":"xiaohongshu","postId":"1"}]}';

      final channel = MethodChannel('mock_verify_channel');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'writeBackupToDirectory') {
          writeCalled = true;
          return 'content://uri/easysave-backup-20261022-1000.json';
        } else if (call.method == 'readDocumentContent') {
          return validJson;
        } else if (call.method == 'rotateBackups') {
          rotateCalled = true;
          return 1;
        }
        return null;
      });

      final resultUri = await SafService.writeAndVerifyBackup(
        treeUri: 'content://tree/target',
        fileName: 'easysave-backup-20261022-1000.json',
        content: validJson,
        expectedPostCount: 1,
        channelOverride: channel,
      );

      expect(resultUri, 'content://uri/easysave-backup-20261022-1000.json');
      expect(writeCalled, isTrue);
      expect(rotateCalled, isTrue);
    });

    test('writeAndVerifyBackup: write failure throws SafException and does NOT rotate (old backups unchanged)', () async {
      var rotateCalled = false;
      int existingBackupsCount = 5;

      final channel = MethodChannel('mock_verify_channel');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'writeBackupToDirectory') {
          throw PlatformException(code: 'IO_ERROR', message: 'Disk failure');
        } else if (call.method == 'rotateBackups') {
          rotateCalled = true;
          existingBackupsCount--;
          return 1;
        }
        return null;
      });

      await expectLater(
        () => SafService.writeAndVerifyBackup(
          treeUri: 'content://tree/target',
          fileName: 'easysave-backup-20261022-1000.json',
          content: '{}',
          expectedPostCount: 1,
          channelOverride: channel,
        ),
        throwsA(isA<SafIOException>()),
      );

      expect(rotateCalled, isFalse);
      expect(existingBackupsCount, 5, reason: 'Old backups count must remain unchanged when write fails');
    });

    test('writeAndVerifyBackup: post count mismatch throws SafVerificationException and does NOT rotate', () async {
      var rotateCalled = false;
      int existingBackupsCount = 5;
      // Read-back content has 1 post, but expected was 2
      const jsonWithOnePost = '{"format":"easysave-backup","formatVersion":1,"exportedAt":"2026-10-22T10:00:00Z","posts":[{"platform":"xiaohongshu","postId":"1"}]}';

      final channel = MethodChannel('mock_verify_channel');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'writeBackupToDirectory') {
          return 'content://uri/easysave-backup-20261022-1000.json';
        } else if (call.method == 'readDocumentContent') {
          return jsonWithOnePost;
        } else if (call.method == 'rotateBackups') {
          rotateCalled = true;
          existingBackupsCount--;
          return 1;
        }
        return null;
      });

      await expectLater(
        () => SafService.writeAndVerifyBackup(
          treeUri: 'content://tree/target',
          fileName: 'easysave-backup-20261022-1000.json',
          content: jsonWithOnePost,
          expectedPostCount: 2, // Mismatch!
          channelOverride: channel,
        ),
        throwsA(isA<SafVerificationException>()),
      );

      expect(rotateCalled, isFalse);
      expect(existingBackupsCount, 5, reason: 'Old backups count must remain unchanged when verification fails');
    });

    test('writeAndVerifyBackup: format mismatch throws SafVerificationException and does NOT rotate', () async {
      var rotateCalled = false;
      int existingBackupsCount = 5;
      const invalidFormatJson = '{"format":"wrong-format","formatVersion":1,"posts":[]}';

      final channel = MethodChannel('mock_verify_channel');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'writeBackupToDirectory') {
          return 'content://uri/file';
        } else if (call.method == 'readDocumentContent') {
          return invalidFormatJson;
        } else if (call.method == 'rotateBackups') {
          rotateCalled = true;
          existingBackupsCount--;
          return 1;
        }
        return null;
      });

      await expectLater(
        () => SafService.writeAndVerifyBackup(
          treeUri: 'content://tree/target',
          fileName: 'easysave-backup-20261022-1000.json',
          content: invalidFormatJson,
          expectedPostCount: 0,
          channelOverride: channel,
        ),
        throwsA(isA<SafVerificationException>()),
      );

      expect(rotateCalled, isFalse);
      expect(existingBackupsCount, 5);
    });
  });
}
