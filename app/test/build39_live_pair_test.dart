import 'dart:convert';

import 'package:easysave/core/models.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/live_pairs.dart';
import 'package:easysave/widgets/gallery_browser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// v1.10.1: a Live photo is one entry. Its still and motion clip must carry the
// pairing identity from the moment the download writes history, and the post
// card, the "最近保存" list and both viewers must count and pair it the same
// way.

const _postId = '6a16921e000000000702897e';
const _postUrl = 'https://www.xiaohongshu.com/explore/$_postId';
const _still = 'https://ci.xiaohongshu.com/notes_pre_post/still';
const _clip = 'https://sns-video-v27.xhscdn.com/stream/1/10/19/clip.mp4?sign=x';

ParsedPost _post(List<MediaItem> items) => ParsedPost(
  platform: 'xhs',
  id: _postId,
  url: _postUrl,
  author: PostAuthor(name: 'author', id: 'uid'),
  items: items,
);

MediaItem _image(String url) => MediaItem(type: 'image', url: url);

MediaItem _live() => MediaItem(type: 'live', url: _still, videoUrl: _clip);

HistoryFile _row(
  String filename, {
  required int itemIndex,
  required bool isImage,
  String? mediaId,
  String? pairId,
  String? assetId,
  FileStatus status = FileStatus.found,
}) => HistoryFile(
  filename: filename,
  savedAt: 1000 + itemIndex,
  mediaId: mediaId,
  status: status,
  itemIndex: itemIndex,
  isImage: isImage,
  pairId: pairId,
  assetId: assetId,
);

/// The batch a "download 1 Live item of a post" produces: the still job and its
/// motion-clip job, both finished and imported.
DownloadBatch _liveBatch({String pairIdPostId = _postId}) => DownloadBatch(
  batchId: 'live-one',
  album: 'EasySave',
  platform: 'xhs',
  postId: _postId,
  postUrl: _postUrl,
  title: 'one live',
  postItemCount: 2,
  itemsJson: jsonEncode([
    _image('https://ci.xiaohongshu.com/notes_pre_post/first').toJson(),
    _live().toJson(),
  ]),
  jobs: [
    DownloadJob(
      key: 'live-still',
      label: 'Live 1',
      filename: '${pairIdPostId}_2.jpg',
      urls: [_still],
      isImage: true,
      itemIndex: 2,
      isLivePhoto: true,
    )
      ..state = JobState.done
      ..saved = true
      ..mediaId = 'media-still'
      ..savedTitle = '${pairIdPostId}_2.jpg'
      ..relativePath = 'Pictures/EasySave/'
      ..assetId = 'asset-still'
      ..fileBytes = 100,
    DownloadJob(
      key: 'live-clip',
      label: 'Live 1',
      filename: '${pairIdPostId}_2.mp4',
      urls: [_clip],
      isImage: false,
      itemIndex: 2,
      isLivePhoto: true,
    )
      ..state = JobState.done
      ..saved = true
      ..mediaId = 'media-clip'
      ..savedTitle = '${pairIdPostId}_2.mp4'
      ..relativePath = 'Pictures/EasySave/'
      ..assetId = 'asset-clip'
      ..fileBytes = 200,
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HistoryDb db;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    DownloadManager.instance.clearBatchesForTesting();
    HistoryDb.resetInstanceForTesting();
    db = await HistoryDb.instance(dbPath: ':memory:');
    HistoryDb.setInstanceForTesting(db);
    await db.clear();
  });
  tearDown(() {
    DownloadManager.instance.clearBatchesForTesting();
    HistoryDb.resetInstanceForTesting();
  });

  group('history rows carry the pairing identity at write time', () {
    test('one downloaded Live item writes two rows that are one entry', () async {
      final batch = _liveBatch();
      await writePlaceholderHistory(db, batch);
      await writeBatchHistory(db, batch, recovered: false);

      final record = (await db.getByPostId(_postId))!;
      expect(record.files, hasLength(2), reason: 'still + motion clip');
      expect(record.files.map((f) => f.itemIndex), [2, 2]);
      expect(record.files.map((f) => f.isImage), [true, false]);
      expect(
        record.files.map((f) => f.filename),
        ['${_postId}_2.jpg', '${_postId}_2.mp4'],
      );
      for (final file in record.files) {
        expect(
          file.pairId,
          '$_postId#2',
          reason: 'the pair identity must be stored with the row, not rebuilt '
              'by a later album scan',
        );
      }
      expect(savedMediaEntryCount(record.savedFiles), 1);
      expect(record.savedFiles, hasLength(2), reason: 'two physical files');
    });

    test('a pairId survives the database round trip', () async {
      final batch = _liveBatch();
      await writeBatchHistory(db, batch, recovered: false);
      final stored = await db.getByPostUrl(_postUrl);
      expect(stored!.files.every((f) => f.pairId == '$_postId#2'), isTrue);
      expect(savedMediaEntryCount(stored.savedFiles), 1);
    });

    test('an ordinary image keeps no pairId', () async {
      final batch = DownloadBatch(
        batchId: 'plain',
        album: 'EasySave',
        platform: 'xhs',
        postId: _postId,
        postUrl: _postUrl,
        postItemCount: 1,
        itemsJson: jsonEncode([_image(_still).toJson()]),
        jobs: [
          DownloadJob(
            key: 'plain-1',
            label: '图片 1',
            filename: '${_postId}_1.jpg',
            urls: [_still],
            isImage: true,
            itemIndex: 1,
          )
            ..state = JobState.done
            ..saved = true
            ..mediaId = 'media-plain',
        ],
      );
      await writeBatchHistory(db, batch, recovered: false);
      final record = (await db.getByPostUrl(_postUrl))!;
      expect(record.files.single.pairId, isNull);
      expect(savedMediaEntryCount(record.savedFiles), 1);
    });
  });

  group('the shared pairing rule', () {
    test('a still and its clip are one entry, whatever the extension is', () {
      final entries = pairSavedMedia([
        _row('${_postId}_2.heic', itemIndex: 2, isImage: true),
        _row('${_postId}_2.mp4', itemIndex: 2, isImage: false),
      ]);
      expect(entries, hasLength(1));
      expect(entries.single.isLive, isTrue);
      expect(entries.single.image!.filename, endsWith('.heic'));
      expect(entries.single.video!.filename, endsWith('.mp4'));
    });

    test('rows that disagree about itemIndex still pair by album name', () {
      final entries = pairSavedMedia([
        _row('${_postId}_2.jpg', itemIndex: 2, isImage: true),
        _row('${_postId}_2.mp4', itemIndex: 3, isImage: false),
      ]);
      expect(entries, hasLength(1));
      expect(entries.single.itemIndex, 2);
      expect(entries.single.isLive, isTrue);
    });

    test('v1.8.2 rows without any pairId pair exactly as before', () {
      final entries = pairSavedMedia([
        _row('${_postId}_1.jpg', itemIndex: 1, isImage: true),
        _row('${_postId}_1.mp4', itemIndex: 1, isImage: false),
        _row('${_postId}_3.mp4', itemIndex: 3, isImage: false),
      ]);
      expect(entries, hasLength(2));
      expect(entries[0].isLive, isTrue);
      expect(entries[1].isLive, isFalse);
      expect(entries[1].itemIndex, 3);
    });

    test('a legacy 0-based set still pairs', () {
      final entries = pairSavedMedia([
        _row('${_postId}_2.jpg', itemIndex: 0, isImage: true,
            status: FileStatus.unknown),
        _row('${_postId}_2.mp4', itemIndex: 0, isImage: false,
            status: FileStatus.unknown),
      ]);
      expect(entries, hasLength(1));
      expect(entries.single.itemIndex, 2);
      expect(entries.single.isLive, isTrue);
    });

    test('conflicting pairIds are not merged', () {
      final entries = pairSavedMedia([
        _row('${_postId}_2.jpg', itemIndex: 2, isImage: true,
            pairId: '$_postId#2'),
        _row('${_postId}_2.mp4', itemIndex: 2, isImage: false,
            pairId: '$_postId#3'),
      ]);
      expect(entries, hasLength(2));
      expect(entries.every((e) => !e.isLive), isTrue);
    });

    test('an ambiguous group is never merged into a Live entry', () {
      final entries = pairSavedMedia([
        _row('${_postId}_2.jpg', itemIndex: 2, isImage: true, mediaId: 'a'),
        _row('${_postId}_2.jpg', itemIndex: 2, isImage: true, mediaId: 'b'),
        _row('${_postId}_2.mp4', itemIndex: 2, isImage: false, mediaId: 'c'),
      ]);
      expect(entries, hasLength(3));
      expect(entries.every((e) => !e.isLive), isTrue);
    });

    test('a mixed post counts one entry per item', () {
      final files = [
        _row('${_postId}_1.jpg', itemIndex: 1, isImage: true),
        _row('${_postId}_2.jpg', itemIndex: 2, isImage: true),
        _row('${_postId}_2.mp4', itemIndex: 2, isImage: false),
        _row('${_postId}_3.mp4', itemIndex: 3, isImage: false),
        _row('${_postId}_4.jpg', itemIndex: 4, isImage: true),
        _row('${_postId}_4.mp4', itemIndex: 4, isImage: false),
      ];
      final entries = pairSavedMedia(files);
      expect(entries.map((e) => e.itemIndex), [1, 2, 3, 4]);
      expect(entries.map((e) => e.isLive), [false, true, false, true]);
      expect(savedMediaEntryCount(files), 4);
    });
  });

  group('viewer items are built from the same pairs', () {
    test('one downloaded Live item opens as one page', () async {
      final batch = _liveBatch();
      await writeBatchHistory(db, batch, recovered: false);
      final record = (await db.getByPostId(_postId))!;
      final post = record.toPost();

      final built = await savedBrowserItems(
        record: record,
        files: record.savedFiles,
        post: post,
        locate: (_) async => null,
      );
      expect(built.items, hasLength(1));
      expect(built.items.single.type, 'live');
      expect(built.items.single.index, 1);
      expect(built.initial, 0);
    });

    test('a mixed post keeps its counts and order', () async {
      final files = [
        _row('${_postId}_1.jpg', itemIndex: 1, isImage: true),
        _row('${_postId}_2.jpg', itemIndex: 2, isImage: true),
        _row('${_postId}_2.mp4', itemIndex: 2, isImage: false),
        _row('${_postId}_3.mp4', itemIndex: 3, isImage: false),
        _row('${_postId}_4.jpg', itemIndex: 4, isImage: true),
        _row('${_postId}_4.mp4', itemIndex: 4, isImage: false),
      ];
      final post = _post([_image(_still), _live(), _live(), _live()]);
      final record = HistoryRecord(
        platform: 'xhs',
        postId: _postId,
        postUrl: _postUrl,
        fileCount: files.length,
        createdAt: DateTime(2026),
        itemsJson: jsonEncode([for (final i in post.items) i.toJson()]),
        files: files,
      );

      final built = await savedBrowserItems(
        record: record,
        files: record.savedFiles,
        post: post,
        locate: (_) async => null,
      );
      expect(built.items.map((i) => i.type), ['image', 'live', 'video', 'live']);
      expect(built.items.map((i) => i.index), [0, 1, 2, 3]);
      expect(savedMediaEntryCount(record.savedFiles), 4);
    });

    test('highlight lands on the paired page, not on the clip', () async {
      final batch = _liveBatch();
      await writeBatchHistory(db, batch, recovered: false);
      final record = (await db.getByPostId(_postId))!;
      final files = record.savedFiles;

      final fromStill = await savedBrowserItems(
        record: record,
        files: files,
        post: record.toPost(),
        highlightItemIndex: 2,
        locate: (_) async => null,
      );
      expect(fromStill.items, hasLength(1));
      expect(fromStill.initial, 0);
    });

    test('the history card counts a Live photo once', () async {
      final batch = _liveBatch();
      await writeBatchHistory(db, batch, recovered: false);
      final record = (await db.getByPostId(_postId))!;
      expect(
        savedMediaEntryCount(record.savedFiles),
        1,
        reason: 'the card badge and the "最近保存" subtitle use this count',
      );
      expect(record.fileCount, 2, reason: 'physical rows stay 2');
    });
  });
}
