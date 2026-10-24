// Copyright 2026 EasySave. All rights reserved.
// Unit test suite for backup and restore (TC-01 through TC-08, TC-01b, TC-03b).

import 'dart:convert';
import 'dart:io';

import 'package:easysave/metadata/provenance_version.dart';
import 'package:easysave/services/backup/backup_model.dart';
import 'package:easysave/services/backup/backup_security.dart';
import 'package:easysave/services/backup/backup_service.dart';
import 'package:easysave/services/backup/local_auto_backup.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late String tempDbPath;
  late Directory tempDir;
  late HistoryDb db;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('easysave_backup_test_');
    tempDbPath = '${tempDir.path}/test_${DateTime.now().microsecondsSinceEpoch}.db';
    HistoryDb.resetInstanceForTesting();
    db = await HistoryDb.instance(dbPath: tempDbPath);
    SharedPreferences.setMockInitialValues({});
    LocalAutoBackup.resetThrottleForTest();
  });

  tearDown(() async {
    HistoryDb.resetInstanceForTesting();
    try {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    } catch (_) {}
  });

  group('BackupService core tests', () {
    test('TC-01: Full round-trip export and import consistency', () async {
      final now = DateTime(2026, 10, 22, 14, 30, 0);

      // Create rich history: XHS post with Live Photo (image + video pair), IG post with image, X post with video
      final xhsRecord = HistoryRecord(
        platform: 'xhs',
        postId: 'xhs_note_123',
        authorName: 'Traveler',
        title: 'Autumn in Paris',
        caption: 'Walking by the river Seine',
        postUrl: 'https://www.xiaohongshu.com/explore/xhs_note_123?xsec_token=sec123',
        fileCount: 2,
        createdAt: now,
        itemsJson: jsonEncode([
          {'type': 'live', 'url': 'https://img/cover.jpg', 'videoUrl': 'https://vid/live.mp4'}
        ]),
        files: [
          HistoryFile(
            filename: 'xhs_123_1.jpg',
            savedAt: now.millisecondsSinceEpoch,
            mediaId: 'm_101',
            itemIndex: 1,
            isImage: true,
            assetId: 'uuid-xhs-img',
            relativePath: 'Pictures/EasySave/',
          ),
          HistoryFile(
            filename: 'xhs_123_1.mp4',
            savedAt: now.millisecondsSinceEpoch,
            mediaId: 'm_102',
            itemIndex: 1,
            isImage: false,
            assetId: 'uuid-xhs-vid',
            relativePath: 'Pictures/EasySave/',
          ),
        ],
      );

      final igRecord = HistoryRecord(
        platform: 'instagram',
        postId: 'ig_post_456',
        authorName: 'Photographer',
        title: 'Sunset',
        caption: 'Golden hour vibes',
        postUrl: 'https://www.instagram.com/p/ig_post_456/',
        fileCount: 1,
        createdAt: now.add(const Duration(minutes: 5)),
        itemsJson: jsonEncode([
          {'type': 'image', 'url': 'https://ig/1.jpg'}
        ]),
        files: [
          HistoryFile(
            filename: 'ig_456_1.jpg',
            savedAt: now.millisecondsSinceEpoch,
            mediaId: 'm_103',
            itemIndex: 1,
            isImage: true,
            assetId: 'uuid-ig-img',
            relativePath: 'Pictures/EasySave/',
          ),
        ],
      );

      await db.upsert(xhsRecord);
      await db.upsert(igRecord);

      final settings = await AppSettings.load();
      settings.albumName = 'CustomAlbum';
      settings.usedAlbumNames = ['CustomAlbum', 'OldAlbum'];
      settings.saveCaptionTxt = true;
      settings.bubbleEnabled = true;
      settings.bubblePreviewSticky = true;
      await settings.save();

      // Export
      final exportedJson = await BackupService.exportBackup(
        db: db,
        settings: settings,
        now: now,
      );

      expect(exportedJson, isNotEmpty);
      final decoded = jsonDecode(exportedJson) as Map<String, dynamic>;
      expect(decoded['format'], 'easysave-backup');
      expect(decoded['formatVersion'], 1);
      expect(decoded['appVersion'], '1.8.0');
      expect(decoded['provenanceSpecVersion'], provenanceSpecVersion);
      expect((decoded['posts'] as List).length, 2);

      // Verify XHS platform converted to spec name 'xiaohongshu'
      final postsList = decoded['posts'] as List;
      final xhsExported = postsList.firstWhere((p) => p['sourceId'] == 'xhs_note_123');
      expect(xhsExported['platform'], 'xiaohongshu');
      expect(xhsExported['items'], isA<List>()); // structured array, not JSON string!

      // Clear database and settings
      await db.clear();
      expect(await db.countActive(), 0);
      final emptySettings = await AppSettings.load();
      emptySettings.albumName = 'EasySave';
      emptySettings.usedAlbumNames = [];
      emptySettings.saveCaptionTxt = false;

      // Import back
      final importResult = await BackupService.importBackup(
        exportedJson,
        db: db,
        settings: emptySettings,
        restoreSettings: true,
        checkOverlayPermission: (type) => true,
      );

      expect(importResult.restoredPosts, 2);
      expect(importResult.restoredFiles, 3);
      expect(importResult.restoredSettings, true);

      // Verify records in DB
      final restoredRecords = await db.getAllActiveForBackup();
      expect(restoredRecords.length, 2);

      final restoredXhs = restoredRecords.firstWhere((r) => r.postId == 'xhs_note_123');
      expect(restoredXhs.platform, 'xhs'); // Converted back to internal ID!
      expect(restoredXhs.authorName, 'Traveler');
      expect(restoredXhs.title, 'Autumn in Paris');
      expect(restoredXhs.caption, 'Walking by the river Seine');
      expect(restoredXhs.files.length, 2);

      final liveImage = restoredXhs.files.firstWhere((f) => f.isImage);
      final liveVideo = restoredXhs.files.firstWhere((f) => !f.isImage);
      expect(liveImage.itemIndex, liveVideo.itemIndex); // Live photo shares same index
      expect(liveImage.assetId, 'uuid-xhs-img');
      expect(liveVideo.assetId, 'uuid-xhs-vid');
      expect(liveImage.relativePath, 'Pictures/EasySave/');

      // Verify restored settings
      expect(emptySettings.albumName, 'CustomAlbum');
      expect(emptySettings.usedAlbumNames, containsAll(['CustomAlbum', 'OldAlbum']));
      expect(emptySettings.saveCaptionTxt, true);
      expect(emptySettings.bubbleEnabled, true);
      expect(emptySettings.bubblePreviewSticky, true);
    });

    test('TC-01b: Empty history protection tests', () async {
      // 1. When history is empty, auto backup should abort and not write any file
      expect(await db.countActive(), 0);
      final customPath = '${tempDir.path}/app_support';
      final backupFile = await LocalAutoBackup.getBackupFile(customSupportDirPath: customPath);
      expect(backupFile.existsSync(), isFalse);

      final didBackup = await LocalAutoBackup.performAutoBackup(
        db: db,
        customSupportDirPath: customPath,
      );
      expect(didBackup, isFalse);
      expect(backupFile.existsSync(), isFalse);

      // 2. Pre-create a non-empty private backup file
      backupFile.parent.createSync(recursive: true);
      await backupFile.writeAsString('{"original":"content"}');
      expect(backupFile.existsSync(), isTrue);

      // Running auto-backup with empty history must NOT overwrite the existing file
      final didBackup2 = await LocalAutoBackup.performAutoBackup(
        db: db,
        customSupportDirPath: customPath,
      );
      expect(didBackup2, isFalse);
      expect(await backupFile.readAsString(), '{"original":"content"}');
    });

    test('2a Correction: LocalAutoBackup writes to .tmp before atomic rename', () async {
      final customPath = '${tempDir.path}/app_support_atomic';
      final backupFile = await LocalAutoBackup.getBackupFile(customSupportDirPath: customPath);
      final tmpFile = File('${backupFile.path}.tmp');

      // Add a record so history is not empty
      await db.upsert(
        HistoryRecord(
          platform: 'xhs',
          postId: 'atomic_post_1',
          postUrl: 'https://example.com/p',
          title: 'Atomic Post',
          fileCount: 0,
          createdAt: DateTime.now(),
          files: [],
        ),
      );

      final didBackup = await LocalAutoBackup.performAutoBackup(
        db: db,
        customSupportDirPath: customPath,
        force: true,
      );

      expect(didBackup, isTrue);
      // Official backup file must exist
      expect(await backupFile.exists(), isTrue);
      // .tmp file must be renamed/consumed, not left behind
      expect(await tmpFile.exists(), isFalse);

      final content = await backupFile.readAsString();
      expect(content, contains('atomic_post_1'));
    });

    test('TC-02: Repeated import is idempotent', () async {
      final now = DateTime(2026, 10, 22, 10, 0, 0);
      final record = HistoryRecord(
        platform: 'x',
        postId: 'tweet_123',
        authorName: 'TechDev',
        title: 'New announcement',
        postUrl: 'https://x.com/TechDev/status/tweet_123',
        fileCount: 1,
        createdAt: now,
        files: [
          HistoryFile(
            filename: 'tweet_123_1.jpg',
            savedAt: now.millisecondsSinceEpoch,
            mediaId: 'm_x1',
            itemIndex: 1,
            isImage: true,
            assetId: 'x-asset-1',
          ),
        ],
      );
      await db.upsert(record);

      final exported = await BackupService.exportBackup(db: db);

      // Import once
      await BackupService.importBackup(exported, db: db);
      expect(await db.countActive(), 1);

      // Import second time
      await BackupService.importBackup(exported, db: db);
      expect(await db.countActive(), 1);

      final all = await db.getAllActiveForBackup();
      expect(all.length, 1);
      expect(all.first.files.length, 1);
    });

    test('TC-03: User-initiated restore restores locally soft-deleted records', () async {
      final now = DateTime(2026, 10, 22, 10, 0, 0);
      final record = HistoryRecord(
        platform: 'xhs',
        postId: 'post_to_delete',
        postUrl: 'https://www.xiaohongshu.com/explore/post_to_delete',
        fileCount: 1,
        createdAt: now,
        files: [
          HistoryFile(
            filename: 'post_1.jpg',
            savedAt: now.millisecondsSinceEpoch,
            itemIndex: 1,
            isImage: true,
          ),
        ],
      );
      await db.upsert(record);

      // Export while active
      final exported = await BackupService.exportBackup(db: db);

      // Now user deletes the record in the app (soft-delete)
      final existing = await db.getByPostId('post_to_delete');
      expect(existing, isNotNull);
      await db.delete(existing!.id!);

      // Confirm it's marked as deleted
      final afterDelete = await db.getByPostId('post_to_delete');
      expect(afterDelete!.isDeleted, isTrue);
      expect(await db.countActive(), 0);

      // Restore from backup (user-initiated action)
      await BackupService.importBackup(exported, db: db);

      // Confirm record is restored to visible state
      final afterRestore = await db.getByPostId('post_to_delete');
      expect(afterRestore, isNotNull);
      expect(afterRestore!.isDeleted, isFalse);
      expect(await db.countActive(), 1);
    });

    test('TC-03b: Locally deleted records are not exported', () async {
      final now = DateTime(2026, 10, 22, 10, 0, 0);
      final active = HistoryRecord(
        platform: 'xhs',
        postId: 'active_post',
        postUrl: 'https://www.xiaohongshu.com/explore/active_post',
        fileCount: 1,
        createdAt: now,
        files: [
          HistoryFile(
            filename: 'active.jpg',
            savedAt: now.millisecondsSinceEpoch,
            itemIndex: 1,
            isImage: true,
          ),
        ],
      );
      final deleted = HistoryRecord(
        platform: 'xhs',
        postId: 'deleted_post',
        postUrl: 'https://www.xiaohongshu.com/explore/deleted_post',
        fileCount: 1,
        createdAt: now,
        files: [
          HistoryFile(
            filename: 'deleted.jpg',
            savedAt: now.millisecondsSinceEpoch,
            itemIndex: 1,
            isImage: true,
          ),
        ],
      );

      await db.upsert(active);
      await db.upsert(deleted);

      // Soft delete deleted_post
      final delRecord = await db.getByPostId('deleted_post');
      await db.delete(delRecord!.id!);

      final exported = await BackupService.exportBackup(db: db);
      final decoded = jsonDecode(exported) as Map<String, dynamic>;
      final posts = decoded['posts'] as List;

      expect(posts.any((p) => p['sourceId'] == 'active_post'), isTrue);
      expect(posts.any((p) => p['sourceId'] == 'deleted_post'), isFalse);
    });

    test('TC-04: Platform identifier bidirectional mapping', () async {
      final now = DateTime(2026, 10, 22);
      final xhs = HistoryRecord(
        platform: 'xhs',
        postId: 'p1',
        postUrl: 'https://www.xiaohongshu.com/explore/p1',
        fileCount: 0,
        createdAt: now,
      );
      final ig = HistoryRecord(
        platform: 'instagram',
        postId: 'p2',
        postUrl: 'https://www.instagram.com/p/p2/',
        fileCount: 0,
        createdAt: now,
      );
      final x = HistoryRecord(
        platform: 'x',
        postId: 'p3',
        postUrl: 'https://x.com/user/status/p3',
        fileCount: 0,
        createdAt: now,
      );

      await db.upsert(xhs);
      await db.upsert(ig);
      await db.upsert(x);

      final exported = await BackupService.exportBackup(db: db);
      final decoded = jsonDecode(exported) as Map<String, dynamic>;
      final posts = decoded['posts'] as List;

      // In exported JSON, spec names must be used
      expect(posts.firstWhere((p) => p['sourceId'] == 'p1')['platform'], 'xiaohongshu');
      expect(posts.firstWhere((p) => p['sourceId'] == 'p2')['platform'], 'instagram');
      expect(posts.firstWhere((p) => p['sourceId'] == 'p3')['platform'], 'x');

      await db.clear();
      await BackupService.importBackup(exported, db: db);

      // After import back, internal app identifiers must be restored
      final p1 = await db.getByPostId('p1');
      final p2 = await db.getByPostId('p2');
      final p3 = await db.getByPostId('p3');

      expect(p1!.platform, 'xhs');
      expect(p2!.platform, 'instagram');
      expect(p3!.platform, 'x');
    });

    test('TC-05: Incompatible version rejection and backwards compatibility', () async {
      // 1. Higher version rejected
      final v2Json = jsonEncode({
        'format': 'easysave-backup',
        'formatVersion': 2,
        'exportedAt': '2026-10-22T10:00:00+08:00',
        'appVersion': '2.0.0',
        'provenanceSpecVersion': '0.1.3',
        'settings': {},
        'posts': [],
      });

      expect(
        () => BackupService.previewBackup(v2Json),
        throwsA(isA<IncompatibleBackupVersionException>()),
      );
      expect(
        () => BackupService.importBackup(v2Json, db: db),
        throwsA(isA<IncompatibleBackupVersionException>()),
      );

      // 2. Old/tolerant format with missing relativePath and missing items
      final oldJson = jsonEncode({
        'format': 'easysave-backup',
        'formatVersion': 1,
        'exportedAt': '2026-10-20T10:00:00+08:00',
        'appVersion': '1.7.0',
        'settings': {'albumName': 'OldSavedAlbum'},
        'posts': [
          {
            'platform': 'xiaohongshu',
            'sourceId': 'old_123',
            'originalUrl': 'https://www.xiaohongshu.com/explore/old_123',
            'createdAt': '2026-10-20T10:00:00+08:00',
            // No relativePath in files, no items in post
            'files': [
              {
                'filename': 'old.jpg',
                'savedAt': '2026-10-20T10:00:00+08:00',
                'mediaType': 'image',
                'itemIndex': 1,
              }
            ],
          }
        ],
      });

      final preview = BackupService.previewBackup(oldJson);
      expect(preview.postCount, 1);
      expect(preview.fileCount, 1);

      await BackupService.importBackup(oldJson, db: db);
      final restored = await db.getByPostId('old_123');
      expect(restored, isNotNull);
      expect(restored!.files.first.relativePath, isNull);
    });

    test('TC-06: Strict sensitive keys audit scan', () async {
      final now = DateTime(2026, 10, 22);
      final record = HistoryRecord(
        platform: 'xhs',
        postId: 'post_with_words',
        authorName: 'author_session_name',
        title: 'Title containing token and auth words',
        caption: 'This caption discusses session tokens and cookies safely in values',
        postUrl: 'https://www.xiaohongshu.com/explore/post_with_words?xsec_token=allowed_url_token',
        fileCount: 1,
        createdAt: now,
        files: [
          HistoryFile(
            filename: 'test.jpg',
            savedAt: now.millisecondsSinceEpoch,
            itemIndex: 1,
            isImage: true,
          ),
        ],
      );
      await db.upsert(record);

      final exported = await BackupService.exportBackup(db: db);
      final decoded = jsonDecode(exported) as Map<String, dynamic>;

      // Assert that JSON object keys do not contain sensitive names
      expect(() => validateNoSensitiveKeys(decoded), returnsNormally);

      // Verify that if a sensitive key were added, the validator catches it
      final badMap = {
        'format': 'easysave-backup',
        'auth_token': 'secret',
      };
      expect(() => validateNoSensitiveKeys(badMap), throwsA(isA<SensitiveDataLeakException>()));

      final badNestedMap = {
        'posts': [
          {
            'cookie': 'session=123',
          }
        ]
      };
      expect(() => validateNoSensitiveKeys(badNestedMap), throwsA(isA<SensitiveDataLeakException>()));
    });

    test('TC-07: Settings restoration, union merge and exclusions', () async {
      final settings = await AppSettings.load();
      settings.albumName = 'MyAlbum';
      settings.usedAlbumNames = ['AlbumA', 'AlbumB'];
      settings.backupTreeUri = 'content://tree/uri/do_not_backup';
      settings.lastBackupTime = 123456789;
      settings.skipRestoreHint = true;
      await settings.save();

      final exported = await BackupService.exportBackup(db: db, settings: settings);
      final decoded = jsonDecode(exported) as Map<String, dynamic>;
      final exportedSettings = decoded['settings'] as Map<String, dynamic>;

      // Explicitly excluded from backup:
      expect(exportedSettings.containsKey('backupTreeUri'), isFalse);
      expect(exportedSettings.containsKey('lastBackupTime'), isFalse);
      expect(exportedSettings.containsKey('skipRestoreHint'), isFalse);

      // Simulate device with different settings
      final currentSettings = await AppSettings.load();
      currentSettings.albumName = 'CurrentAlbum';
      currentSettings.usedAlbumNames = ['AlbumB', 'AlbumC'];
      currentSettings.backupTreeUri = 'content://tree/uri/local';
      currentSettings.lastBackupTime = 999999;
      currentSettings.skipRestoreHint = false;

      // Restore with restoreSettings = true
      await BackupService.importBackup(
        exported,
        db: db,
        settings: currentSettings,
        restoreSettings: true,
      );

      // usedAlbumNames should be a union: AlbumA, AlbumB, AlbumC
      expect(currentSettings.usedAlbumNames, containsAll(['AlbumA', 'AlbumB', 'AlbumC']));
      // Verify list mutability (can add without throwing UnsupportedError)
      expect(() => currentSettings.rememberAlbum('AlbumD'), returnsNormally);
      expect(currentSettings.usedAlbumNames, contains('AlbumD'));

      // Excluded settings should not be overwritten
      expect(currentSettings.backupTreeUri, 'content://tree/uri/local');
      expect(currentSettings.lastBackupTime, 999999);
      expect(currentSettings.skipRestoreHint, false);
    });

    test('TC-08: Floating bubble permission safeguard on restore', () async {
      final settings = await AppSettings.load();
      settings.bubbleEnabled = true;
      await settings.save();

      final exported = await BackupService.exportBackup(db: db, settings: settings);

      final newDeviceSettings = await AppSettings.load();
      newDeviceSettings.bubbleEnabled = false;

      // Case 1: Device does NOT have overlay permission -> bubbleEnabled stays false, notice given
      final result1 = await BackupService.importBackup(
        exported,
        db: db,
        settings: newDeviceSettings,
        restoreSettings: true,
        checkOverlayPermission: (type) => false,
      );

      expect(newDeviceSettings.bubbleEnabled, isFalse);
      expect(result1.overlayNotice, isTrue);

      // Case 2: Device DOES have overlay permission -> bubbleEnabled restored to true
      final result2 = await BackupService.importBackup(
        exported,
        db: db,
        settings: newDeviceSettings,
        restoreSettings: true,
        checkOverlayPermission: (type) => true,
      );

      expect(newDeviceSettings.bubbleEnabled, isTrue);
      expect(result2.overlayNotice, isFalse);
    });

    test('Restore preserving chronological order: newly downloaded post stays on top of older restored posts', () async {
      final now = DateTime.now();
      final todayMorning = DateTime(now.year, now.month, now.day, now.hour, now.minute, now.second).subtract(const Duration(hours: 2));
      final todayLater = DateTime(now.year, now.month, now.day, now.hour, now.minute, now.second).subtract(const Duration(minutes: 10));

      // 1. Old post exported in backup
      final oldPost = HistoryRecord(
        platform: 'xhs',
        postId: 'old_post_1',
        authorName: 'Author',
        title: 'Old Post',
        caption: 'Old Post',
        postUrl: 'https://test.com/old',
        fileCount: 1,
        createdAt: todayMorning,
        files: [
          HistoryFile(
            filename: 'old.jpg',
            savedAt: todayMorning.millisecondsSinceEpoch,
            itemIndex: 1,
            isImage: true,
          ),
        ],
      );
      await db.upsert(oldPost);

      final exported = await BackupService.exportBackup(db: db);

      // User soft-deletes old post (is_deleted = 1)
      final recordInDb = await db.getByPostId('old_post_1');
      await db.delete(recordInDb!.id!);

      // 2. User downloads a new post today (later than the old post)
      final newPost = HistoryRecord(
        platform: 'xhs',
        postId: 'new_post_2',
        authorName: 'Author',
        title: 'New Post',
        caption: 'New Post',
        postUrl: 'https://test.com/new',
        fileCount: 1,
        createdAt: todayLater,
        files: [
          HistoryFile(
            filename: 'new.jpg',
            savedAt: todayLater.millisecondsSinceEpoch,
            itemIndex: 1,
            isImage: true,
          ),
        ],
      );
      await db.upsert(newPost);

      // 3. User restores old backup data
      await BackupService.importBackup(exported, db: db);

      // 4. Query recent sorted by created_at DESC (as used by HistoryPage)
      final all = await db.recent();
      expect(all.length, 2);
      expect(all[0].postId, 'new_post_2', reason: 'New download must stay on top of older restored post');
      expect(all[1].postId, 'old_post_1');
      expect(all[1].createdAt.millisecondsSinceEpoch, todayMorning.millisecondsSinceEpoch,
          reason: 'Restored post must keep its original createdAt and not be set to DateTime.now()');
    });
  });
}
