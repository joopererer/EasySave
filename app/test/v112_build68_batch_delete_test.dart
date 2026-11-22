// Copyright 2026 EasySave. All rights reserved.
// v1.12 build 68: batch item deletion in fullscreen viewer and item count alignment.

import 'dart:convert';

import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/history_item_delete.dart';
import 'package:easysave/services/live_pairs.dart';
import 'package:easysave/services/media_delete_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _postId = '55889922114433';

HistoryFile _row(
  int index, {
  FileStatus status = FileStatus.found,
  String? mediaId,
  bool image = true,
}) =>
    HistoryFile(
      filename: '${_postId}_$index.${image ? 'jpg' : 'mp4'}',
      savedAt: 1,
      mediaId: mediaId ?? '${index}0${image ? 1 : 2}',
      status: status,
      itemIndex: index,
      isImage: image,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('5.5b: post deletion count aligns across Live photos and items', () {
    test('Live photo (still + clip) counts as 1 item in savedItemCountFor and savedMediaEntryCount', () {
      final liveStill = _row(1, image: true, mediaId: '101');
      final liveClip = _row(1, image: false, mediaId: '102');
      final normalImage = _row(2, image: true, mediaId: '201');

      final record = HistoryRecord(
        platform: 'xhs',
        postId: _postId,
        postUrl: 'https://www.xiaohongshu.com/explore/$_postId',
        title: 'Test Live Photo Post',
        fileCount: 3,
        createdAt: DateTime(2026),
        itemsJson: jsonEncode([
          {'type': 'live_photo'},
          {'type': 'image'},
        ]),
        files: [liveStill, liveClip, normalImage],
      );

      // Must count as 2 items (Live photo = 1 item, normal image = 1 item)
      expect(savedItemCountFor([record]), 2);
      expect(savedMediaEntryCount(record.savedFiles), 2);

      final refs = [
        MediaRef(mediaId: '101', isImage: true),
        MediaRef(mediaId: '102', isImage: false),
        MediaRef(mediaId: '201', isImage: true),
      ];
      expect(deletableItemCountFor([record], refs), 2);
    });
  });

  group('5.5a: batch item deletion', () {
    late HistoryDb db;

    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      HistoryDb.resetInstanceForTesting();
      db = await HistoryDb.instance(dbPath: ':memory:');
      HistoryDb.setInstanceForTesting(db);
      await db.clear();
    });

    tearDown(() => HistoryDb.resetInstanceForTesting());

    Future<HistoryRecord> seed(List<HistoryFile> files) async {
      await db.upsert(
        HistoryRecord(
          platform: 'xhs',
          postId: _postId,
          postUrl: 'https://www.xiaohongshu.com/explore/$_postId',
          title: 'Batch Delete Test',
          fileCount: files.length,
          createdAt: DateTime(2026),
          itemsJson: jsonEncode([
            for (var i = 1; i <= files.length; i++)
              {'type': 'image', 'url': 'https://sns-img.xhscdn.com/$i.jpg'},
          ]),
          files: files,
        ),
      );
      return (await db.getByPostId(_postId))!;
    }

    test('combines all MediaRefs into a single deleteMedia call', () async {
      final record = await seed([
        _row(1, mediaId: 'id_1'),
        _row(2, mediaId: 'id_2'),
        _row(3, mediaId: 'id_3'),
      ]);

      final calls = <List<String>>[];
      final outcome = await deleteHistoryItems(
        record,
        itemIndices: {0, 2},
        deleteAlbumFiles: true,
        deleteMedia: (media) async {
          calls.add([for (final m in media) m.mediaId]);
          return MediaDeleteOutcome(
            approved: true,
            requested: media.length,
            remaining: 0,
          );
        },
      );

      // Single call with both IDs!
      expect(calls, hasLength(1));
      expect(calls.single, ['id_1', 'id_3']);
      expect(outcome.ok, isTrue);
      expect(outcome.cancelled, isFalse);
      expect(outcome.succeededIndices, {0, 2});

      final after = (await db.getByPostId(_postId))!;
      expect(after.files.firstWhere((f) => f.itemIndex == 1).status, FileStatus.deleted);
      expect(after.files.firstWhere((f) => f.itemIndex == 2).status, FileStatus.found);
      expect(after.files.firstWhere((f) => f.itemIndex == 3).status, FileStatus.deleted);
    });

    test('cancelling system delete confirmation aborts without deleting any record', () async {
      final record = await seed([
        _row(1, mediaId: 'id_1'),
        _row(2, mediaId: 'id_2'),
      ]);

      final calls = <List<String>>[];
      final outcome = await deleteHistoryItems(
        record,
        itemIndices: {0, 1},
        deleteAlbumFiles: true,
        deleteMedia: (media) async {
          calls.add([for (final m in media) m.mediaId]);
          return MediaDeleteOutcome(
            approved: false,
            requested: media.length,
          );
        },
      );

      expect(calls, hasLength(1));
      expect(outcome.ok, isFalse);
      expect(outcome.cancelled, isTrue);

      final after = (await db.getByPostId(_postId))!;
      expect(after.files.every((f) => f.status == FileStatus.found), isTrue);
    });

    test('partial album failure reports problem and still updates database', () async {
      final record = await seed([
        _row(1, mediaId: 'id_1'),
        _row(2, mediaId: 'id_2'),
      ]);

      final outcome = await deleteHistoryItems(
        record,
        itemIndices: {0, 1},
        deleteAlbumFiles: true,
        deleteMedia: (media) async => const MediaDeleteOutcome(
          approved: true,
          requested: 2,
          remaining: 1,
        ),
      );

      expect(outcome.ok, isTrue);
      expect(outcome.cancelled, isFalse);
      expect(outcome.problem, isNotNull);

      final after = (await db.getByPostId(_postId))!;
      expect(after.files.every((f) => f.status == FileStatus.deleted), isTrue);
    });
  });
}
