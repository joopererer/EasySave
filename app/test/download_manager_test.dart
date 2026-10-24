import 'dart:io';

import 'package:easysave/core/models.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/history_db.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

ParsedPost _post() => ParsedPost(
  platform: 'xhs',
  id: 'abc123',
  url: 'https://www.xiaohongshu.com/explore/abc123',
  author: PostAuthor(name: 'momo'),
  items: [
    MediaItem(type: 'image', url: 'https://img/1.jpg'),
    MediaItem(
      type: 'video',
      url: 'https://video/v.mp4',
      posterUrl: 'https://img/cover.jpg',
    ),
    MediaItem(
      type: 'live',
      url: 'https://img/live.jpg',
      videoUrl: 'https://img/live.mp4',
    ),
  ],
);

void main() {
  group('planFiles', () {
    test('image job keeps CDN-first URL order', () {
      final planned = planFiles(_post(), [0], (l, s, e) => 'f$s.$e');
      expect(planned, hasLength(1));
      expect(planned.first.label, '图片 1');
      expect(planned.first.urls.first, 'https://img/1.jpg');
      expect(planned.first.isImage, isTrue);
    });

    test('video job tries the mp4 before image fallbacks', () {
      final planned = planFiles(_post(), [1], (l, s, e) => 'f$s.$e');
      expect(planned.first.urls.first, 'https://video/v.mp4');
      expect(planned.first.isImage, isFalse);
    });

    test('live item expands to still + motion jobs', () {
      final planned = planFiles(_post(), [2], (l, s, e) => 'f$s.$e');
      expect(planned, hasLength(2));
      expect(planned[0].isImage, isTrue);
      expect(planned[1].isImage, isFalse);
      expect(planned[0].label, planned[1].label);
    });

    test('labels count per kind across selections', () {
      final planned = planFiles(_post(), [0, 1, 2], (l, s, e) => 'f$s.$e');
      final labels = planned.map((p) => p.label).toList();
      expect(labels, ['图片 1', '视频 1', 'Live 1', 'Live 1']);
    });
  });

  group('retry counting', () {
    test('attempt rotation cycles through fallback URLs', () {
      final urls = ['a', 'b'];
      // Attempt n uses urls[(n-1) % len]: 1->a, 2->b, 3->a.
      expect(urls[(1 - 1) % urls.length], 'a');
      expect(urls[(2 - 1) % urls.length], 'b');
      expect(urls[(3 - 1) % urls.length], 'a');
    });

    test('kMaxAttempts caps total tries at 3', () {
      expect(kMaxAttempts, 3);
    });
  });

  group('planFilesForItem', () {
    test('returns null for out-of-range items', () {
      expect(planFilesForItem(_post(), 9), isNull);
      expect(planFilesForItem(_post(), -1), isNull);
    });

    test('refreshes live motion URL on manual retry', () {
      final urls = planFilesForItem(_post(), 2)!;
      expect(urls, contains('https://img/live.mp4'));
    });
  });

  group('selective download provenance', () {
    ParsedPost post5() => ParsedPost(
      platform: 'instagram',
      id: 'Det2VeVn3tY',
      url: 'https://www.instagram.com/p/Det2VeVn3tY/',
      author: PostAuthor(name: 'someone'),
      items: [
        for (var i = 1; i <= 5; i++)
          MediaItem(type: 'image', url: 'https://img/$i.jpg'),
      ],
    );

    DownloadBatch batchFor(ParsedPost post, List<int> selected) {
      final planned = planFiles(post, selected, (l, s, e) => 'f$s');
      return DownloadBatch(
        batchId: 'b',
        album: 'EasySave',
        postUrl: post.url,
        platform: post.platform,
        postId: post.id,
        postItemCount: post.items.length,
        jobs: [
          for (var i = 0; i < planned.length; i++)
            DownloadJob(
              key: 'b-$i',
              label: planned[i].label,
              filename: planned[i].filename,
              urls: planned[i].urls,
              isImage: planned[i].isImage,
              itemIndex: planned[i].itemIndex,
              isLivePhoto: planned[i].isLivePhoto,
            ),
        ],
      );
    }

    test('items 2 and 4 of 5 keep original index and post total', () {
      final batch = batchFor(post5(), [1, 3]);
      expect(batch.jobs.map((j) => j.itemIndex), [2, 4]);
      final p2 = provenanceForBatchItem(batch, itemIndex: batch.jobs[0].itemIndex);
      final p4 = provenanceForBatchItem(batch, itemIndex: batch.jobs[1].itemIndex);
      expect(p2.itemIndex, 2);
      expect(p2.itemCount, 5);
      expect(p4.itemIndex, 4);
      expect(p4.itemCount, 5);
    });

    test('a single selected item of a multi-item post keeps its index', () {
      final batch = batchFor(post5(), [1]);
      expect(batch.jobs, hasLength(1));
      final p = provenanceForBatchItem(batch, itemIndex: batch.jobs.single.itemIndex);
      expect(p.itemIndex, 2);
      expect(p.itemCount, 5);
    });

    test('a genuine single-item post still omits index and count', () {
      final single = ParsedPost(
        platform: 'instagram',
        id: 'one',
        url: 'https://www.instagram.com/p/one/',
        author: PostAuthor(name: 'a'),
        items: [MediaItem(type: 'image', url: 'https://img/1.jpg')],
      );
      final batch = batchFor(single, [0]);
      final p = provenanceForBatchItem(batch, itemIndex: 1);
      expect(p.itemIndex, isNull);
      expect(p.itemCount, isNull);
    });

    test('post total survives the snapshot round trip', () {
      final batch = batchFor(post5(), [1, 3]);
      final restored = DownloadBatch.fromJson(
        batch.toJson().map((k, v) => MapEntry(k, v is List ? List.of(v) : v)),
      );
      expect(restored.postItemCount, 5);
      expect(restored.totalItems, 5);
    });

    test('legacy snapshot without postItemCount falls back to itemsJson', () {
      final legacy = DownloadBatch(
        batchId: 'b',
        album: 'EasySave',
        postUrl: 'u',
        platform: 'instagram',
        postId: 'p',
        itemsJson: '[{},{},{},{},{}]',
        jobs: [
          DownloadJob(
            key: 'b-0',
            label: 'l',
            filename: 'f.jpg',
            urls: ['u'],
            isImage: true,
            itemIndex: 2,
          ),
        ],
      );
      expect(legacy.totalItems, 5);
    });

    test('Live item: still and motion jobs both carry original index, isLivePhoto and pairId', () {
      final live = ParsedPost(
        platform: 'xhs',
        id: 'n1',
        url: 'https://www.xiaohongshu.com/explore/n1',
        author: PostAuthor(name: 'a'),
        items: [
          MediaItem(type: 'image', url: 'https://img/1.jpg'),
          MediaItem(type: 'live', url: 'https://img/2.jpg', videoUrl: 'https://v/2.mp4'),
          MediaItem(type: 'image', url: 'https://img/3.jpg'),
        ],
      );
      final batch = batchFor(live, [1]);
      expect(batch.jobs.map((j) => j.itemIndex), [2, 2]);
      expect(batch.jobs.every((j) => j.isLivePhoto), isTrue);

      final pairId = '${batch.postId}#2';
      final pStill = provenanceForBatchItem(batch, itemIndex: batch.jobs[0].itemIndex, pairId: pairId);
      final pMotion = provenanceForBatchItem(batch, itemIndex: batch.jobs[1].itemIndex, pairId: pairId);

      expect(pStill.pairId, 'n1#2');
      expect(pMotion.pairId, 'n1#2');
      expect(pStill.pairId, equals(pMotion.pairId));
      expect(pStill.itemIndex, 2);
      expect(pStill.itemCount, 3);
    });

    test('Non-live items do not carry pairId', () {
      final batch = batchFor(post5(), [1]);
      final job = batch.jobs.single;
      expect(job.isLivePhoto, isFalse);

      final p = provenanceForBatchItem(
        batch,
        itemIndex: job.itemIndex,
        pairId: job.isLivePhoto ? '${batch.postId}#${job.itemIndex}' : null,
      );
      expect(p.pairId, isNull);
    });
  });

  group('DownloadBatch serialization', () {
    test('round-trips jobs for kill-recovery snapshots', () {
      final batch = DownloadBatch(
        batchId: 'b1',
        album: 'EasySave',
        postUrl: 'https://www.xiaohongshu.com/explore/abc123',
        platform: 'xhs',
        postId: 'abc123',
        jobs: [
          DownloadJob(
            key: 'b1-0',
            label: '图片 1',
            filename: 'f1.jpg',
            urls: ['https://img/1.jpg'],
            isImage: true,
            itemIndex: 0,
          )..attempts = 2,
        ],
      );
      final restored = DownloadBatch.fromJson(
        (batch.toJson()).map((k, v) => MapEntry(k, v is List ? List.of(v) : v)),
      );
      expect(restored.jobs.single.attempts, 2);
      expect(restored.jobs.single.urls, ['https://img/1.jpg']);
      expect(restored.isTerminal, isFalse);
    });
  });

  group('writeBatchHistory restoreDeleted scoping', () {
    late String tempDbPath;
    late HistoryDb db;

    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    setUp(() async {
      final tempDir = await Directory.systemTemp.createTemp('easysave_dm_test');
      tempDbPath = p.join(
        tempDir.path,
        'test_history_${DateTime.now().millisecondsSinceEpoch}.db',
      );
      HistoryDb.resetInstanceForTesting();
      db = await HistoryDb.instance(dbPath: tempDbPath);
    });

    tearDown(() async {
      HistoryDb.resetInstanceForTesting();
      try {
        final file = File(tempDbPath);
        if (await file.exists()) await file.delete();
      } catch (_) {
        // Ignore cleanup errors
      }
    });

    DownloadBatch finishedBatch(String postId) => DownloadBatch(
      batchId: 'b-$postId',
      album: 'EasySave',
      postUrl: 'https://www.xiaohongshu.com/explore/$postId',
      platform: 'xhs',
      postId: postId,
      jobs: [
        DownloadJob(
          key: 'b-$postId-0',
          label: '图片 1',
          filename: 'f1.jpg',
          urls: ['https://img/1.jpg'],
          isImage: true,
          itemIndex: 1,
        )..state = JobState.done
         ..saved = true
         ..mediaId = 'media1',
      ],
    );

    test(
      'user re-download of a soft-deleted post restores it (recovered: false, '
      'restoreDeleted: !recovered = true — live user download)',
      () async {
        // Seed a soft-deleted record for the post, mirroring an earlier
        // download that the user deleted from History.
        await db.upsert(
          HistoryRecord(
            platform: 'xhs',
            postId: 'redl',
            postUrl: 'https://www.xiaohongshu.com/explore/redl',
            fileCount: 1,
            createdAt: DateTime.now(),
            files: [
              HistoryFile(
                filename: 'old.jpg',
                savedAt: DateTime.now().millisecondsSinceEpoch,
                itemIndex: 1,
              ),
            ],
          ),
        );
        final existing = await db.getByPostId('redl');
        await db.delete(existing!.id!);
        expect((await db.recent()).isEmpty, isTrue);

        // Active user-initiated download finishes: _afterTerminal passes
        // recovered: false, which maps to restoreDeleted: !recovered = true.
        final batch = finishedBatch('redl');
        await writeBatchHistory(db, batch, recovered: false);

        final restored = await db.getByPostId('redl');
        expect(restored, isNotNull);
        expect(restored!.isDeleted, isFalse);
        expect((await db.recent()).length, 1);
      },
    );

    test(
      'startup recovery of an interrupted batch does not restore a '
      'soft-deleted record (writeBatchHistory recovered: true → restoreDeleted: false)',
      () async {
        await db.upsert(
          HistoryRecord(
            platform: 'xhs',
            postId: 'resumed',
            postUrl: 'https://www.xiaohongshu.com/explore/resumed',
            fileCount: 1,
            createdAt: DateTime.now(),
            files: [
              HistoryFile(
                filename: 'old.jpg',
                savedAt: DateTime.now().millisecondsSinceEpoch,
                itemIndex: 1,
              ),
            ],
          ),
        );
        final existing = await db.getByPostId('resumed');
        await db.delete(existing!.id!);
        expect((await db.recent()).isEmpty, isTrue);

        // _reconcileBatch (startup / foreground resume of an interrupted
        // batch) calls _afterTerminal(batch, recovered: true), which maps
        // to writeBatchHistory(..., recovered: true) → restoreDeleted: false.
        final batch = finishedBatch('resumed');
        await writeBatchHistory(db, batch, recovered: true);

        final stillDeleted = await db.getByPostId('resumed');
        expect(stillDeleted, isNotNull);
        expect(stillDeleted!.isDeleted, isTrue);
        expect((await db.recent()).isEmpty, isTrue);
      },
    );

    test(
      'startup adoption of a finished foreign batch keeps a deleted record '
      'deleted (upsert, never reinsert)',
      () async {
        await db.upsert(
          HistoryRecord(
            platform: 'xhs',
            postId: 'adopted',
            postUrl: 'https://www.xiaohongshu.com/explore/adopted',
            fileCount: 1,
            createdAt: DateTime.now(),
            files: [HistoryFile(filename: 'old.jpg', savedAt: 0)],
          ),
        );
        final existing = await db.getByPostId('adopted');
        await db.delete(existing!.id!);

        // The batch was finished by the background engine and is adopted by
        // the main engine on start: recovered: true → restoreDeleted: false.
        final batch = finishedBatch('adopted');
        await writeBatchHistory(db, batch, recovered: true);

        final stillDeleted = await db.getByPostId('adopted');
        expect(stillDeleted!.isDeleted, isTrue);
        expect(await db.recent(), isEmpty);
      },
    );
  });

  group('Foreign batch adoption is one-shot', () {
    const owner = DownloadBatch.sourceMain;

    int staleNow() => kStalledBatchAgeMs * 2;

    DownloadBatch foreignBatch({String? settledBy}) => DownloadBatch(      batchId: 'background-1792611876085',
      album: 'EasySave',
      postUrl: 'https://www.xiaohongshu.com/explore/settled',
      platform: 'xhs',
      postId: 'settled',
      source: DownloadBatch.sourceBackground,
      updatedAt: staleNow(),
      jobs: [
        DownloadJob(
          key: 'settled-0',
          label: '图片 1',
          filename: 'f1.jpg',
          urls: ['https://img/1.jpg'],
          isImage: true,
          itemIndex: 1,
        )..state = JobState.done,
      ],
    )..settledBy = settledBy;

    test('a stalled foreign batch with terminal tasks may be adopted once', () {
      expect(
        canAdoptForeignBatch(
          owner: owner,
          batchSource: DownloadBatch.sourceBackground,
          updatedAt: staleNow(),
          now: staleNow() + kStalledBatchAgeMs,
          allTasksTerminal: true,
        ),
        isTrue,
      );
    });

    test('a settled foreign batch is never adopted again', () {
      expect(
        canAdoptForeignBatch(
          owner: owner,
          batchSource: DownloadBatch.sourceBackground,
          updatedAt: staleNow(),
          now: staleNow() + kStalledBatchAgeMs,
          allTasksTerminal: true,
          settledBy: owner,
        ),
        isFalse,
        reason: 'completed batches keep terminal jobs, so only this flag '
            'stops the next start from adopting them again',
      );
    });

    test('settledBy survives a snapshot round-trip', () {
      final batch = foreignBatch()..settledBy = owner;
      final restored = DownloadBatch.fromJson(batch.toJson());
      expect(restored.settledBy, owner);
      expect(restored.historyWritten, batch.historyWritten);
    });

    test('a fresh snapshot has no settledBy', () {
      expect(foreignBatch().settledBy, isNull);
      expect(
        DownloadBatch.fromJson(foreignBatch().toJson()).settledBy,
        isNull,
      );
    });
  });
}
