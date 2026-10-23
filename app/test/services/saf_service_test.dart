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
    test('formatBackupFileName formats exactly to easysave-backup-YYYYMMDD-HHmmss.json', () {
      final dt = DateTime(2026, 10, 22, 14, 5, 30);
      final filename = formatBackupFileName(dt);
      expect(filename, 'easysave-backup-20261022-140530.json');
      expect(extractBackupTimestamp(filename), '20261022-140530');
      expect(parseBackupTimestamp(filename), dt);
    });

    test('parseBackupTimestamp parses both legacy HHmm and new HHmmss format', () {
      final legacy = parseBackupTimestamp('easysave-backup-20261022-1405.json');
      expect(legacy, DateTime(2026, 10, 22, 14, 5, 0));

      final withSeconds = parseBackupTimestamp('easysave-backup-20261022-140530.json');
      expect(withSeconds, DateTime(2026, 10, 22, 14, 5, 30));
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

    test('mixed old (HHmm) and new (HHmmss) format files are sorted chronologically by time, not string', () {
      final fileList = [
        'easysave-backup-20261022-1401.json',   // 14:01:00 (old) -> 9th (pruned)
        'easysave-backup-20261022-140530.json', // 14:05:30 (new) -> 2nd
        'easysave-backup-20261022-1404.json',   // 14:04:00 (old) -> 5th
        'easysave-backup-20261022-140600.json', // 14:06:00 (new) -> 1st (newest)
        'easysave-backup-20261022-140459.json', // 14:04:59 (new) -> 4th
        'easysave-backup-20261022-1402.json',   // 14:02:00 (old) -> 7th (kept boundary)
        'easysave-backup-20261022-1405.json',   // 14:05:00 (old) -> 3rd
        'easysave-backup-20261022-140159.json', // 14:01:59 (new) -> 8th (pruned)
        'easysave-backup-20261022-140300.json', // 14:03:00 (new) -> 6th
      ];

      final pruneCandidates = getPruneCandidates(fileList, keepCount: 7);

      expect(pruneCandidates, [
        'easysave-backup-20261022-140159.json',
        'easysave-backup-20261022-1401.json',
      ]);
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
      expect(writtenFileName, 'easysave-backup-20261022-163000.json');
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

  group('Step 4 / Feedback 1: Content Deduplication and Equivalence', () {
    test('isBackupContentEquivalent ignores exportedAt but detects data changes', () {
      const baseJson = '''
      {
        "format": "easysave-backup",
        "formatVersion": 1,
        "exportedAt": "2026-10-23T10:00:00.000Z",
        "settings": {"autoDownload": true},
        "posts": [{"platform": "xhs", "postId": "p1"}]
      }
      ''';

      const diffTimestampJson = '''
      {
        "format": "easysave-backup",
        "formatVersion": 1,
        "exportedAt": "2026-10-23T11:00:00.000Z",
        "settings": {"autoDownload": true},
        "posts": [{"platform": "xhs", "postId": "p1"}]
      }
      ''';

      const diffPostsJson = '''
      {
        "format": "easysave-backup",
        "formatVersion": 1,
        "exportedAt": "2026-10-23T10:00:00.000Z",
        "settings": {"autoDownload": true},
        "posts": [{"platform": "xhs", "postId": "p2"}]
      }
      ''';

      expect(isBackupContentEquivalent(baseJson, diffTimestampJson), isTrue);
      expect(isBackupContentEquivalent(baseJson, diffPostsJson), isFalse);
      expect(isBackupContentEquivalent('not-json', baseJson), isFalse);
    });

    test('deduplication: identical content skips write & rotation, modified content writes & rotates', () async {
      final tempDir = await Directory.systemTemp.createTemp('saf_dedup_test_');
      final dbPath = '${tempDir.path}/test_history_dedup.db';
      final db = await HistoryDb.instance(dbPath: dbPath);
      await db.clear();
      SafService.resetThrottleForTest();

      await db.upsert(
        HistoryRecord(
          platform: 'xhs',
          postId: 'post_first',
          postUrl: 'https://example.com/p1',
          title: 'Post 1',
          fileCount: 0,
          createdAt: DateTime.now(),
          files: [],
        ),
      );

      final settings = AppSettings()..backupTreeUri = 'content://tree/target';
      Map<String, dynamic>? latestBackupInFolder;
      final writes = <String>[];
      var rotateCount = 0;

      final channel = MethodChannel('mock_dedup_channel');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getLatestBackup') {
          return latestBackupInFolder;
        } else if (call.method == 'writeBackupToDirectory') {
          final name = call.arguments['fileName'] as String;
          final content = call.arguments['content'] as String;
          writes.add(name);
          latestBackupInFolder = {
            'name': name,
            'uri': 'content://uri/$name',
            'content': content,
          };
          return 'content://uri/$name';
        } else if (call.method == 'readDocumentContent') {
          return latestBackupInFolder?['content'] as String? ?? '';
        } else if (call.method == 'rotateBackups') {
          rotateCount++;
          return 0;
        }
        return null;
      });

      // 1. First manual backup: folder is empty, should write and rotate
      final time1 = DateTime(2026, 10, 23, 10, 0, 0);
      final res1 = await SafService.performManualBackupToDirectory(
        'content://tree/target',
        db: db,
        settings: settings,
        now: time1,
        channelOverride: channel,
      );

      expect(res1.isIdentical, isFalse);
      expect(writes.length, 1);
      expect(writes.first, 'easysave-backup-20261023-100000.json');
      expect(rotateCount, 1);
      expect(settings.lastBackupTime, time1.millisecondsSinceEpoch);

      // 2. Second manual backup immediately without history change:
      // must detect identical content, NOT create new file, NOT rotate, but update lastBackupTime
      final time2 = DateTime(2026, 10, 23, 10, 5, 0);
      final res2 = await SafService.performManualBackupToDirectory(
        'content://tree/target',
        db: db,
        settings: settings,
        now: time2,
        channelOverride: channel,
      );

      expect(res2.isIdentical, isTrue);
      expect(writes.length, 1, reason: 'No new file should be written when content is identical');
      expect(rotateCount, 1, reason: 'No rotation should occur when content is identical');
      expect(settings.lastBackupTime, time2.millisecondsSinceEpoch, reason: 'lastBackupTime must be updated');

      // 3. Auto-backup with same content: skips write and rotation
      final time3 = DateTime(2026, 10, 23, 11, 30, 0); // After throttle duration
      final autoRes = await SafService.performAutoBackupToDirectory(
        db: db,
        settings: settings,
        now: time3,
        channelOverride: channel,
      );

      expect(autoRes, isTrue);
      expect(writes.length, 1);
      expect(rotateCount, 1);
      expect(settings.lastBackupTime, time3.millisecondsSinceEpoch);

      // 4. Modify history (add a second post)
      await db.upsert(
        HistoryRecord(
          platform: 'xhs',
          postId: 'post_second',
          postUrl: 'https://example.com/p2',
          title: 'Post 2',
          fileCount: 0,
          createdAt: DateTime.now(),
          files: [],
        ),
      );

      // 5. Third manual backup with changed content: writes new file and rotates
      final time4 = DateTime(2026, 10, 23, 12, 0, 0);
      final res3 = await SafService.performManualBackupToDirectory(
        'content://tree/target',
        db: db,
        settings: settings,
        now: time4,
        channelOverride: channel,
      );

      expect(res3.isIdentical, isFalse);
      expect(writes.length, 2, reason: 'New file must be written when content changes');
      expect(writes.last, 'easysave-backup-20261023-120000.json');
      expect(rotateCount, 2, reason: 'Rotation must occur when content changes');
      expect(settings.lastBackupTime, time4.millisecondsSinceEpoch);
    });
  });

  group('Feedback 2: Readable Directory Path Parsing & Fallback', () {
    test('parseTreeDocumentPath handles primary internal storage paths', () {
      expect(
        parseTreeDocumentPath('content://com.android.externalstorage.documents/tree/primary%3ADocuments%2FEasySave'),
        '内部存储/Documents/EasySave',
      );
      expect(
        parseTreeDocumentPath('content://com.android.externalstorage.documents/tree/primary%3A'),
        '内部存储',
      );
      expect(
        parseTreeDocumentPath('content://com.android.externalstorage.documents/tree/primary'),
        '内部存储',
      );
      expect(
        parseTreeDocumentPath('content://com.android.providers.downloads.documents/tree/raw%3A%2Fstorage%2Femulated%2F0%2FDownload'),
        '内部存储/Download',
      );
    });

    test('parseTreeDocumentPath handles secondary SD card volumes', () {
      expect(
        parseTreeDocumentPath('content://com.android.externalstorage.documents/tree/1234-5678%3AMyBackups%2FEasySave'),
        'SD 卡/MyBackups/EasySave',
      );
      expect(
        parseTreeDocumentPath('content://com.android.externalstorage.documents/tree/0000-0000%3A'),
        'SD 卡',
      );
    });

    test('parseTreeDocumentPath returns null for opaque or non-volume URIs', () {
      expect(
        parseTreeDocumentPath('content://com.android.providers.downloads.documents/tree/downloads'),
        isNull,
      );
      expect(
        parseTreeDocumentPath('content://custom.provider/opaque/12345'),
        isNull,
      );
    });

    test('formatReadableDirectoryPath falls back to DocumentFile name or generic title, never raw URI', () {
      // 1. Parsable returns parsed string
      expect(
        SafService.formatReadableDirectoryPath('content://com.android.externalstorage.documents/tree/primary%3ADocuments%2FEasySave'),
        '内部存储/Documents/EasySave',
      );

      // 2. Unparsable with fallback DocumentFile name
      expect(
        SafService.formatReadableDirectoryPath(
          'content://com.android.providers.downloads.documents/tree/downloads',
          fallbackName: 'Downloads',
        ),
        'Downloads',
      );

      // 3. Unparsable with null or raw URI fallback
      expect(
        SafService.formatReadableDirectoryPath('content://com.android.providers.downloads.documents/tree/downloads'),
        '外部备份文件夹',
      );
      expect(
        SafService.formatReadableDirectoryPath(
          'content://com.android.providers.downloads.documents/tree/downloads',
          fallbackName: 'content://com.android.providers.downloads.documents/tree/downloads',
        ),
        '外部备份文件夹',
      );
    });

    test('getDirectoryDisplayName invokes platform channel', () async {
      final channel = MethodChannel('mock_display_name_channel');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getDirectoryDisplayName') {
          return 'EasySave';
        }
        return null;
      });

      final name = await SafService.getDirectoryDisplayName(
        'content://tree/target',
        channelOverride: channel,
      );
      expect(name, 'EasySave');
    });
  });
}
