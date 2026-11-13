import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/export_names.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/live_pairs.dart';
import 'package:easysave/services/media_content_type.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// v1.10.1 build 41: still downloads are quality-first. An original-resolution
// candidate (ci:jpg / img / ci) wins over any preview-size candidate
// (webpic / WB_PRV / preview size): HEIC / AVIF originals are saved in their
// own container with provenance skipped, previews are only used when every
// original candidate failed and keep the "非原图" mark.

const _postId = '6a29621b000000003501e972';
const _postUrl = 'https://www.xiaohongshu.com/explore/$_postId';

const _cjpeg =
    'https://ci.xiaohongshu.com/notes_pre_post/still?imageView2/format/jpg';
const _cImgHeic = 'https://sns-img-bd.xhscdn.com/notes_pre_post/original.heic';
const _cImgJpg = 'https://sns-img-bd.xhscdn.com/notes_pre_post/original.jpg';
const _cWebp =
    'https://sns-webpic-qc.xhscdn.com/202610112129/abc/notes_pre_post/still!nd_dft_wlteh_webp_3';
const _cClip =
    'https://sns-video-v27.xhscdn.com/stream/1/10/19/01ea342f_19.mp4?sign=secret';

Uint8List _fourCc(String value) => Uint8List.fromList(value.codeUnits);

Uint8List _box(String type, List<int> body) {
  final size = 8 + body.length;
  return Uint8List.fromList([
    (size >> 24) & 0xff,
    (size >> 16) & 0xff,
    (size >> 8) & 0xff,
    size & 0xff,
    ..._fourCc(type),
    ...body,
  ]);
}

Uint8List _ftyp(String major, [List<String> compatible = const []]) => _box('ftyp', [
  ..._fourCc(major), 0, 0, 0, 0,
  for (final brand in compatible) ..._fourCc(brand),
]);

Uint8List _heicStill() => Uint8List.fromList([
  ..._ftyp('heic', ['mif1', 'heic']),
  ..._box('meta', List.filled(40, 0)),
  ..._box('mdat', List.filled(64, 3)),
]);

Uint8List _webp() => Uint8List.fromList([
  ..._fourCc('RIFF'), 12, 0, 0, 0, ..._fourCc('WEBP'),
]);
DownloadJob _job({
  required List<String> urls,
  required bool isImage,
  int itemIndex = 1,
  bool isLivePhoto = false,
  int attempts = 1,
}) {
  final job = DownloadJob(
    key: 'job-$itemIndex',
    label: isLivePhoto ? 'Live 1' : '图片 $itemIndex',
    filename: '${_postId}_$itemIndex.jpg',
    urls: urls,
    isImage: isImage,
    itemIndex: itemIndex,
    isLivePhoto: isLivePhoto,
  )
    ..attempts = attempts;
  return job;
}

DownloadBatch _batch(List<DownloadJob> jobs) => DownloadBatch(
  batchId: 'quality-priority',
  album: 'EasySave',
  postUrl: _postUrl,
  platform: 'xhs',
  postId: _postId,
  itemsJson: '[]',
  postItemCount: jobs.length,
  jobs: jobs,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final manager = DownloadManager.instance;
  late List<String> logs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    SiteRegistry.useBuiltin();
    manager.clearBatchesForTesting();
    logs = <String>[];
    debugPrint = (message, {wrapWidth}) => logs.add(message ?? '');
  });

  tearDown(() async {
    debugPrint = debugPrintThrottled;
    candidateRetryBackoffsForTesting = kCandidateRetryBackoffs;
    manager
      ..enqueueForTesting = null
      ..mediaContentTypeForTesting = null
      ..gallerySaveForTesting = null
      ..tempRootForTesting = null
      ..clearBatchesForTesting();
    SiteRegistry.useBuiltin();
  });

  group('quality-first candidate order', () {
    test('jpeg original first, HEIC original next, preview last', () {
      final ranked = rankStillCandidates([
        _cWebp,
        _cImgHeic,
        _cjpeg,
      ]);
      expect(ranked, [_cjpeg, _cImgHeic, _cWebp]);
    });

    test('a HEIC original beats a WebP preview even though WebP is writable', () {
      final ranked = rankStillCandidates([
        _cWebp,
        _cImgHeic,
      ]);
      expect(ranked.first, _cImgHeic);
      expect(ranked.last, _cWebp);
    });

    test('candidate labels never contain a URL, host, query or token', () {
      for (final url in [_cjpeg, _cImgHeic, _cImgJpg, _cWebp, _cClip]) {
        final label = candidateLabelOf(url);
        expect(label, isNot(contains('http')));
        expect(label, isNot(contains('?')));
        expect(label, isNot(contains('sign')));
        expect(label, isNot(contains('xiaohongshu')));
      }
      expect(candidateLabelOf(_cjpeg), 'ci:jpg');
      expect(candidateLabelOf(_cImgHeic), 'img:heic');
      expect(candidateLabelOf(_cWebp), 'webpic');
    });
  });

  group('an original HEIC / AVIF still is saved as-is', () {
    Future<File> write(String name, Uint8List bytes) async {
      final dir = await Directory.systemTemp.createTemp('easysave_quality');
      final file = File('${dir.path}/$name');
      await file.writeAsBytes(bytes);
      return file;
    }

    // The finished HEIC bytes are accepted on the first candidate: no next
    // candidate is enqueued and no preview is tried.
    test('HEIC original: accepted, provenance skipped, .heic name', () async {
      final job = _job(urls: [_cImgHeic, _cWebp], isImage: true, attempts: 1);
      final file = await write('still-heic.jpg', _heicStill());
      try {
        manager.setBatchForTesting(_batch([job]));
        var enqueued = 0;
        manager.enqueueForTesting = (_, _) async => enqueued++;

        await manager.contentVerdictForTesting(
          _batch([job]),
          job,
          file.path,
          content: detectMediaContentType(_heicStill()),
        );

        expect(enqueued, 0, reason: 'a HEIC original ends the candidate chain');
        expect(await file.exists(), isTrue);
        expect(job.state, isNot(JobState.failed));

        final written = await manager.embedProvenanceForTesting(
          _batch([job]),
          job,
          file.path,
        );
        expect(written, isNull);
        expect(job.provenanceSkipped, isTrue);
        expect(logs.join('\n'), contains('result=ok:provenance_skipped'));

        // The album name and MIME follow the real container.
        final name = await exportNameFor(
          file.path, _postId, 1,
        );
        expect(name, '${_postId}_1.heic');
        expect(exportMime((await exportTypeFor(file.path))), 'image/heic');

        // A Live photo's still still pairs with its clip as one entry.
        expect(job.isLivePhoto, isFalse);
        final liveJob = _job(
          urls: [_cImgHeic],
          isImage: true,
          itemIndex: 2,
          isLivePhoto: true,
          attempts: 1,
        );
        final written2 = await manager.embedProvenanceForTesting(
          _batch([liveJob]),
          liveJob,
          file.path,
        );
        expect(written2, isNull);
        expect(liveJob.provenanceSkipped, isTrue);
        expect(liveJob.isLivePhoto, isTrue);
      } finally {
        if (await file.exists()) await file.delete();
      }
    });

    test('AVIF original: accepted, provenance skipped', () async {
      final job = _job(urls: [_cImgHeic], isImage: true, attempts: 1);
      manager.setBatchForTesting(_batch([job]));
      final file = await write('still-avif.jpg', _heicStill());
      try {
        await manager.contentVerdictForTesting(
          _batch([job]),
          job,
          file.path,
          content: const MediaContentType(
            MediaContentKind.image,
            'avif',
            'image/avif',
          ),
        );
        expect(job.state, isNot(JobState.failed));
        expect(await file.exists(), isTrue);
      } finally {
        if (await file.exists()) await file.delete();
      }
    });

    test('an ordinary image follows the same rule', () async {
      final job = _job(urls: [_cImgHeic, _cWebp], isImage: true, attempts: 1);
      manager.setBatchForTesting(_batch([job]));
      final file = await write('plain-heic.jpg', _heicStill());
      try {
        await manager.contentVerdictForTesting(
          _batch([job]),
          job,
          file.path,
          content: detectMediaContentType(_heicStill()),
        );
        expect(job.state, isNot(JobState.failed));
        final written = await manager.embedProvenanceForTesting(
          _batch([job]),
          job,
          file.path,
        );
        expect(written, isNull);
        expect(job.provenanceSkipped, isTrue);
        expect(job.notOriginal, isFalse);
        expect(job.isLivePhoto, isFalse);
      } finally {
        if (await file.exists()) await file.delete();
      }
    });
  });

  group('previews are used only when every original candidate failed', () {
    TaskStatusUpdate failureFor(String url, int attempt) =>
        TaskStatusUpdate(
          DownloadTask(taskId: 'job-1-try$attempt', url: url, filename: 'x.jpg'),
          TaskStatus.failed,
          TaskException('Connection reset by peer'),
        );

    test('reset retries the same candidate up to three times, then rotates; '
        'every other failure rotates at once', ()
        async {
      candidateRetryBackoffsForTesting = const [Duration.zero];
      final job = _job(
        urls: [_cjpeg, _cImgHeic, _cImgJpg, _cWebp],
        isImage: true,
      );
      manager.setBatchForTesting(_batch([job]));
      manager.enqueueForTesting = (_, j) async => j.attempts++;

      // ci:jpg is reset three times: every retry keeps the same candidate.
      final first = DownloadManager.candidateUrlOf(job)!;
      for (var retry = 1; retry <= kCandidateRetryLimit; retry++) {
        await manager.taskFailureForTesting(
          _batch([job]), job,
          failureFor(first, retry),
        );
        expect(DownloadManager.candidateUrlOf(job), first,
            reason: 'reset retry $retry keeps the same candidate');
      }
      final log1 = logs.join('\n');
      expect(log1, contains('cause=reset'));
      expect(log1, contains('retry=backoff'));
      expect(log1, contains('retry_index=1/$kCandidateRetryLimit'));
      expect(log1,
          contains('retry_index=$kCandidateRetryLimit/$kCandidateRetryLimit'));
      expect(log1, isNot(contains('http')));

      // The next reset on the same candidate retires it: move to img:heic.
      await manager.taskFailureForTesting(
        _batch([job]), job,
        failureFor(first, 20),
      );
      expect(DownloadManager.candidateUrlOf(job), _cImgHeic);

      // A non-transient failure rotates immediately, no backoff.
      await manager.taskFailureForTesting(
        _batch([job]), job,
        TaskStatusUpdate(
          DownloadTask(taskId: 'job-1-try21', url: _cImgHeic, filename: 'x.jpg'),
          TaskStatus.failed,
          TaskException('boom'),
        ),
      );
      expect(DownloadManager.candidateUrlOf(job), _cImgJpg);

      // img:jpg is reset: the ladder keeps it on the same candidate.
      await manager.taskFailureForTesting(
        _batch([job]), job,
        failureFor(_cImgJpg, 22),
      );
      expect(DownloadManager.candidateUrlOf(job), _cImgJpg);
    });

    test('the ladder ends without wrap-around: readable failure and one log '
        'line per attempt', ()
        async {
      candidateRetryBackoffsForTesting = const [Duration.zero];
      final job = _job(
        urls: [_cWebp],
        isImage: true,
      );
      manager.setBatchForTesting(_batch([job]));
      manager.enqueueForTesting = (_, j) async => j.attempts++;

      // 1 transfer + three retries on the only candidate, then the item fails.
      for (var i = 0; i <= kCandidateRetryLimit; i++) {
        await manager.taskFailureForTesting(
          _batch([job]), job,
          failureFor(_cWebp, i + 1),
        );
      }

      expect(job.state, JobState.failed);
      expect(job.error, '第1项图片下载失败');
      expect(job.error, isNot(contains('TaskConnectionException')));
      expect(job.error, isNot(contains('reset')));

      // Every attempt logged one line; no URL, host, query or token leaked.
      final failureLines = logs.where((line) => line.contains('result=transfer_failed')).toList();
      expect(failureLines, hasLength(1 + kCandidateRetryLimit),
          reason: 'one line per attempt');
      for (final line in failureLines) {
        expect(line, isNot(contains('http')));
        expect(line, isNot(contains('sign')));
        expect(line, isNot(contains('xiaohongshu')));
        expect(line, contains('host_class='));
        expect(line, contains('cause='));
      }
    });

    test('retry cap: one attempt per stored candidate, plus three backoff '
        'retries each', () {
      final job = _job(
        urls: [_cjpeg, _cImgHeic, _cImgJpg, _cWebp],
        isImage: true,
      );
      // 4 candidates x (1 transfer + 3 reset/timeout retries).
      expect(retryCapFor(_batch([job]), job), 4 * (1 + kCandidateRetryLimit));

      // A video keeps the site rule (max 3 attempts per file) with the same
      // retry allowance.
      final videoJob = _job(
        urls: [_cClip],
        isImage: false,
      );
      expect(
        retryCapFor(_batch([videoJob]), videoJob),
        attemptCapFor(_batch([videoJob]), videoJob) *
            (1 + kCandidateRetryLimit),
      );
    });

    test('the reset ladder is 0.6s, 1.2s, 2.4s and then stops', () {
      expect(candidateBackoffFor(1), const Duration(milliseconds: 600));
      expect(candidateBackoffFor(2), const Duration(milliseconds: 1200));
      expect(candidateBackoffFor(3), const Duration(milliseconds: 2400));
      expect(kCandidateRetryLimit, 3);
    });

    test('a preview accepted after the originals failed marks 非原图',
        () async {
      final job = _job(
        urls: [_cjpeg, _cImgHeic, _cImgJpg, _cWebp],
        isImage: true,
        attempts: 4,
      )
        ..candidateIndex = 3;
      manager.setBatchForTesting(_batch([job]));
      final file = await File('${Directory.systemTemp.path}/preview.webp')
          .create(recursive: false)
          .then((_) async {
        final f = File('${Directory.systemTemp.path}/preview.webp');
        await f.writeAsBytes(_webp());
        return f;
      });
      try {
        await manager.finishFileForTesting(
          _batch([job]),
          job,
          file.path,
          content: detectMediaContentType(_webp()),
        );
        expect(job.state, isNot(JobState.failed));
        expect(job.notOriginal, isTrue, reason: 'preview-size file');
        expect(logs.join('\n'), contains('not_original=true'));

        // The same job with an original candidate is never marked.
        final original = _job(
          urls: [_cImgHeic],
          isImage: true,
          attempts: 1,
        );
        await manager.finishFileForTesting(
          _batch([original]),
          original,
          file.path,
          content: detectMediaContentType(_heicStill()),
        );
        expect(original.notOriginal, isFalse);
      } finally {
        if (await file.exists()) await file.delete();
      }
    });
  });

  group('a Live HEIC still pairs with its clip as one entry', () {
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

    test('HEIC still row and mp4 row keep pairId and count as one entry', ()
        async {
      final batch = _batch([
        _job(
          urls: [_cImgHeic],
          isImage: true,
          itemIndex: 3,
          isLivePhoto: true,
          attempts: 1,
        )
          ..state = JobState.done
          ..saved = true
          ..mediaId = 'media-still'
          ..savedTitle = '${_postId}_3.heic'
          ..relativePath = 'Pictures/EasySave/'
          ..assetId = 'asset-still'
          ..fileBytes = 212806
          ..provenanceSkipped = true,
        _job(
          urls: [_cClip],
          isImage: false,
          itemIndex: 3,
          isLivePhoto: true,
          attempts: 1,
        )
          ..state = JobState.done
          ..saved = true
          ..mediaId = 'media-clip'
          ..savedTitle = '${_postId}_3.mp4'
          ..relativePath = 'Movies/EasySave/'
          ..assetId = 'asset-clip'
          ..fileBytes = 1908217,
      ]);
      await writeBatchHistory(db, batch, recovered: false);

      final record = (await db.getByPostId(_postId))!;
      expect(record.fileCount, 2);
      for (final file in record.files) {
        expect(file.pairId, '$_postId#3');
        expect(file.notOriginal, isFalse);
      }
      expect(savedMediaEntryCount(record.files), 1,
          reason: 'still + motion clip are one entry');
      final entries = pairSavedMedia(record.files);
      expect(entries, hasLength(1));
      expect(entries.single.isLive, isTrue);
      expect(entries.single.image!.filename, endsWith('.heic'));
      expect(entries.single.video!.filename, endsWith('.mp4'));
    });
  });
}
