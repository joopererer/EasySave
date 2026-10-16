import 'dart:convert';
import 'dart:io';

import 'package:easysave/services/history_db.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('HistoryDb v1 to v2 migration', () {
    late String testDbPath;

    setUp(() async {
      HistoryDb.resetInstanceForTesting();
      final tempDir = Directory.systemTemp.createTempSync('history_db_test_');
      testDbPath = '${tempDir.path}/test_migration.db';
    });

    tearDown(() async {
      HistoryDb.resetInstanceForTesting();
      try {
        final file = File(testDbPath);
        if (file.existsSync()) {
          file.deleteSync();
        }
      } catch (_) {}
    });

    test('migrates v1 database to v2 and infers files as unknown without data loss', () async {
      // 1. Setup a genuine v1 database manually.
      final v1Db = await openDatabase(
        testDbPath,
        version: 1,
        onCreate: (db, version) async {
          await db.execute(
            'CREATE TABLE history_records('
            'id INTEGER PRIMARY KEY AUTOINCREMENT,'
            'platform TEXT NOT NULL,'
            'post_id TEXT NOT NULL,'
            'author_name TEXT,'
            'title TEXT,'
            'caption TEXT,'
            'thumbnail_url TEXT,'
            'post_url TEXT NOT NULL UNIQUE,'
            'file_count INTEGER NOT NULL,'
            'created_at INTEGER NOT NULL,'
            'items_json TEXT)',
          );
        },
      );

      final post1Created = DateTime(2026, 10, 15, 10, 0);
      final post1Items = [
        {'type': 'image', 'url': 'https://cdn/1.jpg'},
        {'type': 'image', 'url': 'https://cdn/2.jpg'},
      ];

      final post2Created = DateTime(2026, 10, 16, 15, 30);
      final post2Items = [
        {
          'type': 'live',
          'url': 'https://cdn/live.jpg',
          'videoUrl': 'https://cdn/live.mp4',
        },
        {
          'type': 'video',
          'url': 'https://cdn/video.mp4',
        },
      ];

      await v1Db.insert('history_records', {
        'platform': 'xhs',
        'post_id': 'post123',
        'author_name': 'alice',
        'title': 'Test Post 1',
        'caption': 'Caption 1',
        'thumbnail_url': 'https://cdn/thumb1.jpg',
        'post_url': 'https://xhs.com/post123',
        'file_count': 2,
        'created_at': post1Created.millisecondsSinceEpoch,
        'items_json': jsonEncode(post1Items),
      });

      await v1Db.insert('history_records', {
        'platform': 'x',
        'post_id': '987654321',
        'author_name': 'bob',
        'title': null,
        'caption': 'Tweet with live and video',
        'thumbnail_url': 'https://cdn/thumb2.jpg',
        'post_url': 'https://x.com/bob/status/987654321',
        'file_count': 3,
        'created_at': post2Created.millisecondsSinceEpoch,
        'items_json': jsonEncode(post2Items),
      });

      await v1Db.close();

      // 2. Open with HistoryDb.instance at version 2.
      final historyDb = await HistoryDb.instance(dbPath: testDbPath);
      final recentRecords = await historyDb.recent();

      expect(recentRecords.length, equals(2));

      // Records preserved in descending createdAt order
      final migratedPost2 = recentRecords.firstWhere((r) => r.postId == '987654321');
      final migratedPost1 = recentRecords.firstWhere((r) => r.postId == 'post123');

      // Verify post1
      expect(migratedPost1.title, equals('Test Post 1'));
      expect(migratedPost1.authorName, equals('alice'));
      expect(migratedPost1.files.length, equals(2));
      expect(migratedPost1.files[0].filename, equals('post123_1.jpg'));
      expect(migratedPost1.files[0].status, equals(FileStatus.unknown));
      expect(migratedPost1.files[0].mediaId, isNull);
      expect(migratedPost1.files[0].savedAt, equals(post1Created.millisecondsSinceEpoch));
      expect(migratedPost1.files[1].filename, equals('post123_2.jpg'));
      expect(migratedPost1.files[1].status, equals(FileStatus.unknown));

      // Verify post2 (Live item expands to .jpg + .mp4, and video item is .mp4)
      expect(migratedPost2.files.length, equals(3));
      expect(migratedPost2.files[0].filename, equals('987654321_1.jpg'));
      expect(migratedPost2.files[0].isImage, isTrue);
      expect(migratedPost2.files[0].status, equals(FileStatus.unknown));

      expect(migratedPost2.files[1].filename, equals('987654321_1.mp4'));
      expect(migratedPost2.files[1].isImage, isFalse);
      expect(migratedPost2.files[1].status, equals(FileStatus.unknown));

      expect(migratedPost2.files[2].filename, equals('987654321_2.mp4'));
      expect(migratedPost2.files[2].isImage, isFalse);
      expect(migratedPost2.files[2].status, equals(FileStatus.unknown));

      // 3. Test updating file status in v2
      final updatedFiles = [
        migratedPost1.files[0].copyWith(
          status: FileStatus.found,
          mediaId: 'asset_1001',
        ),
        migratedPost1.files[1].copyWith(
          status: FileStatus.notFound,
        ),
      ];

      await historyDb.updateFiles(migratedPost1.id!, updatedFiles);
      final reloadedPost1 = await historyDb.getByPostId('post123');
      expect(reloadedPost1, isNotNull);
      expect(reloadedPost1!.files[0].status, equals(FileStatus.found));
      expect(reloadedPost1.files[0].mediaId, equals('asset_1001'));
      expect(reloadedPost1.files[1].status, equals(FileStatus.notFound));

      // 4. Test upsert merges newly downloaded files with existing files
      final newDownloadRecord = HistoryRecord(
        platform: 'xhs',
        postId: 'post123',
        authorName: 'alice',
        title: 'Test Post 1',
        postUrl: 'https://xhs.com/post123',
        fileCount: 1,
        createdAt: DateTime.now(),
        files: [
          HistoryFile(
            filename: 'post123_3.jpg',
            savedAt: DateTime.now().millisecondsSinceEpoch,
            status: FileStatus.unknown,
            itemIndex: 2,
            isImage: true,
          ),
        ],
      );

      await historyDb.upsert(newDownloadRecord);
      final mergedPost1 = await historyDb.getByPostId('post123');
      expect(mergedPost1, isNotNull);
      // Retains previously downloaded files (0, 1) + newly downloaded file (2)
      expect(mergedPost1!.files.length, equals(3));
      expect(mergedPost1.fileCount, equals(3));
      expect(mergedPost1.files.map((f) => f.itemIndex).toList(), equals([0, 1, 2]));
      // The found status and mediaId on item 0 are preserved!
      expect(mergedPost1.files[0].status, equals(FileStatus.found));
      expect(mergedPost1.files[0].mediaId, equals('asset_1001'));
    });
  });
}

