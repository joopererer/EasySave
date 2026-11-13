// Copyright 2026 EasySave. All rights reserved.
// v1.11 batch 4: re-downloading what is not on this device, and deleting a
// single item of a post.
//
// Re-download parses the original post again and opens the preview selection
// with exactly the missing items ticked — a post that lost items, needs a
// login or is gone entirely is reported, never downloaded in its place.
//
// Deleting one item has two modes: record only (undoable) and record plus the
// album file (through the system confirmation, not undoable). A declined system
// dialog still deletes the record and says the file was kept.

import 'dart:convert';

import 'package:easysave/core/models.dart';
import 'package:easysave/pages/preview_page.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/history_item_delete.dart';
import 'package:easysave/services/media_delete_service.dart';
import 'package:easysave/services/parse_service.dart';
import 'package:easysave/widgets/history_browser_flow.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _postId = '2118566677374022101';

ParsedPost _post(int items) => ParsedPost(
  platform: 'xhs',
  id: _postId,
  url: 'https://www.xiaohongshu.com/explore/$_postId',
  author: PostAuthor(name: 'Author'),
  items: [
    for (var i = 0; i < items; i++)
      MediaItem(type: 'image', url: 'https://sns-img.xhscdn.com/$i.jpg'),
  ],
);

HistoryFile _row(int index, {FileStatus status = FileStatus.found, String? mediaId, bool image = true}) =>
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

  group('preselection', () {
    test('only the asked items are preselected', () {
      expect(preselectableIndices(_post(8), {2, 5}), {2, 5});
    });

    test('an index the post no longer has is dropped, not remapped', () {
      expect(preselectableIndices(_post(3), {1, 7}), {1});
      expect(preselectableIndices(_post(3), {7}), isEmpty);
    });
  });

  group('failure copy', () {
    test('a deleted post, a login wall and a lost token each say their own thing',
        () {
      expect(
        redownloadFailureMessage(
          ParseFailure(ParseErrorCode.postNotFound, '找不到'),
        ),
        contains('原帖已不可访问'),
      );
      expect(
        redownloadFailureMessage(
          ParseFailure(ParseErrorCode.loginRequired, '登录'),
        ),
        contains('登录'),
      );
      expect(
        redownloadFailureMessage(
          ParseFailure(ParseErrorCode.tokenRequired, 'token'),
        ),
        contains('凭证'),
      );
      expect(
        redownloadFailureMessage(ParseFailure('SOMETHING_NEW', '自定义说明')),
        '自定义说明',
      );
    });
  });

  group('the preview opens with the requested items ticked', () {
    testWidgets('only the preselected items count in the save button',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: PreviewPage(post: _post(4), initialSelection: {1, 3}),
        ),
      );
      await tester.pump();
      expect(find.text('保存到相册（2）'), findsOneWidget);
      expect(find.text('2/4'), findsNothing,
          reason: 'the badge counts the selected order, not the item slot');
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a fresh parse still ticks everything', (tester) async {
      await tester.pumpWidget(MaterialApp(home: PreviewPage(post: _post(3))));
      await tester.pump();
      expect(find.text('保存到相册（3）'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('deleting one item', () {
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
          title: 'Delete',
          fileCount: files.length,
          createdAt: DateTime(2026),
          itemsJson: jsonEncode([
            for (var i = 0; i < 4; i++)
              {'type': 'image', 'url': 'https://sns-img.xhscdn.com/$i.jpg'},
          ]),
          files: files,
        ),
      );
      return (await db.getByPostId(_postId))!;
    }

    test('record only: the row becomes deleted and the undo restores it',
        () async {
      final record = await seed([
        _row(1),
        _row(2, status: FileStatus.notFound),
      ]);
      final outcome = await deleteHistoryItem(
        record,
        itemIndex: 0,
        deleteAlbumFiles: false,
      );
      expect(outcome.ok, isTrue);
      expect(outcome.problem, isNull);
      expect(outcome.visibleRemaining, 1);

      final after = (await db.getByPostId(_postId))!;
      expect(after.files.first.status, FileStatus.deleted);
      expect(after.missingFiles.map((f) => f.itemIndex).toList(), [2]);
      expect(after.visibleFiles.map((f) => f.itemIndex).toList(), [2]);
      expect(after.originalItemCount, 4,
          reason: 'the raw total never shrinks');

      await undoHistoryItemDelete(db, record.id!, outcome.before);
      final restored = (await db.getByPostId(_postId))!;
      expect(restored.files.first.status, FileStatus.found);
      expect(restored.visibleFiles, hasLength(2));
    });

    test('with the album file: the rows go through the system delete', () async {
      final record = await seed([_row(1), _row(2)]);
      final asked = <List<String>>[];
      final outcome = await deleteHistoryItem(
        record,
        itemIndex: 0,
        deleteAlbumFiles: true,
        deleteMedia: (media) async {
          asked.add([for (final m in media) m.mediaId]);
          return MediaDeleteOutcome(
            approved: true,
            requested: media.length,
          );
        },
      );
      expect(asked, [
        ['101'],
      ]);
      expect(outcome.ok, isTrue);
      expect(outcome.deleteAlbumFiles, isTrue);
      expect(outcome.problem, isNull);
      final after = (await db.getByPostId(_postId))!;
      expect(after.files.first.status, FileStatus.deleted);
    });

    test('a declined system dialog deletes the record and says the file stayed',
        () async {
      final record = await seed([_row(1)]);
      final outcome = await deleteHistoryItem(
        record,
        itemIndex: 0,
        deleteAlbumFiles: true,
        deleteMedia: (media) async => MediaDeleteOutcome(
          approved: false,
          requested: media.length,
        ),
      );
      expect(outcome.ok, isTrue);
      expect(outcome.problem, contains('相册文件未删除'));
      final after = (await db.getByPostId(_postId))!;
      expect(after.files.single.status, FileStatus.deleted);
      expect(after.visibleFiles, isEmpty);
      expect(outcome.visibleRemaining, 0, reason: 'the post has nothing left');
    });

    test('a Live photo is deleted as a pair, never by half', () async {
      final still = _row(1);
      final clip = _row(1, image: false);
      final record = await seed([still, clip, _row(2)]);
      final outcome = await deleteHistoryItem(
        record,
        itemIndex: 0,
        deleteAlbumFiles: false,
      );
      expect(outcome.ok, isTrue);
      final after = (await db.getByPostId(_postId))!;
      expect(
        after.files.where((f) => f.itemIndex == 1).map((f) => f.status).toSet(),
        {FileStatus.deleted},
      );
      expect(after.visibleFiles.map((f) => f.itemIndex).toList(), [2]);
      expect(outcome.visibleRemaining, 1);
    });

    test('an item the album never located cannot claim to be deleted there',
        () async {
      final record = await seed([
        HistoryFile(
          filename: '${_postId}_1.jpg',
          savedAt: 1,
          status: FileStatus.found,
          itemIndex: 1,
          isImage: true,
        ),
      ]);
      final outcome = await deleteHistoryItem(
        record,
        itemIndex: 0,
        deleteAlbumFiles: true,
        deleteMedia: (media) async => throw StateError('must not be called'),
      );
      expect(outcome.ok, isTrue);
      expect(outcome.problem, contains('未找到'));
    });
  });
}
