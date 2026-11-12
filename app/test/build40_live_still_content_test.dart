import 'dart:convert';
import 'dart:io';

import 'package:easysave/core/models.dart';
import 'package:easysave/services/download_claims.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/export_names.dart';
import 'package:easysave/services/media_content_type.dart';
import 'package:easysave/services/parse_service.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// v1.10.1 build 40: a Live photo's still must never fail because the CDN
// answers with HEIC/AVIF, must never be imported from a movie candidate, and
// its failure message must be readable ("第3项实况的静态图保存失败").

const _cjpeg = 'https://ci.xiaohongshu.com/notes_pre_post/still?imageView2/format/jpg';
const _cCdn = 'https://sns-img-bd.xhscdn.com/notes_pre_post/still';
const _cCdnHeic = 'https://sns-img-bd.xhscdn.com/notes_pre_post/original.heic';
const _cClip = 'https://sns-video-v27.xhscdn.com/stream/1/10/19/01ea342f_19.mp4?sign=secret';

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

Uint8List _avifStill() => Uint8List.fromList([
  ..._ftyp('avif', ['mif1', 'avif']),
  ..._box('mdat', List.filled(64, 5)),
]);

Uint8List _mp4({bool withMoov = true}) => Uint8List.fromList([
  ..._ftyp('isom', ['isom', 'mp41']),
  if (withMoov) ..._box('moov', List.filled(120, 0)),
  ..._box('mdat', List.filled(256, 7)),
]);

Uint8List _jpeg() =>
    Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0, 16, ...List.filled(32, 0)]);

ParsedPost _post(List<MediaItem> items, {String id = '6a29621b000000003501e972'}) =>
    ParsedPost(
      platform: 'xhs',
      id: id,
      url: 'https://www.xiaohongshu.com/explore/$id',
      author: PostAuthor(name: 'a', id: 'b'),
      items: items,
    );

DownloadJob _stillJob({List<String>? urls, int itemIndex = 3}) => DownloadJob(
  key: 'job-still-$itemIndex',
  label: 'Live 1',
  filename: '6a29621b000000003501e972_$itemIndex.jpg',
  urls: urls ?? [_cjpeg],
  isImage: true,
  itemIndex: itemIndex,
  isLivePhoto: true,
);

DownloadJob _clipJob({int itemIndex = 3}) => DownloadJob(
  key: 'job-clip-$itemIndex',
  label: 'Live 1',
  filename: '6a29621b000000003501e972_$itemIndex.mp4',
  urls: ['$_cClip&try=0'],
  isImage: false,
  itemIndex: itemIndex,
  isLivePhoto: true,
);

DownloadBatch _batch(List<DownloadJob> jobs) => DownloadBatch(
  batchId: 'live-still-content',
  album: 'EasySave',
  postUrl: 'https://www.xiaohongshu.com/explore/6a29621b000000003501e972',
  platform: 'xhs',
  postId: '6a29621b000000003501e972',
  jobs: jobs,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final manager = DownloadManager.instance;
  late Directory temp;
  late List<String> logs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    SiteRegistry.useBuiltin();
    manager.clearBatchesForTesting();
    temp = await Directory.systemTemp.createTemp('easysave_live_still');
    logs = <String>[];
    debugPrint = (message, {wrapWidth}) => logs.add(message ?? '');
    manager.tempRootForTesting = () async => temp;
  });

  tearDown(() async {
    debugPrint = debugPrintThrottled;
    manager
      ..enqueueForTesting = null
      ..mediaContentTypeForTesting = null
      ..reparseForTesting = null
      ..tempRootForTesting = null
      ..clearBatchesForTesting();
    await DownloadClaims.release('live-still-content');
    SiteRegistry.useBuiltin();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<File> write(String name, Uint8List bytes) async =>
      File('${temp.path}/$name').writeAsBytes(bytes);

  group('candidate ranking is the same for a Live still and an ordinary image', () {
    test('jpeg candidates come first, HEIC/AVIF last, order kept inside a rank', () {
      final ranked = rankStillCandidates([
        _cCdnHeic,
        _cCdn,
        _cjpeg,
        'https://sns-img-bd.xhscdn.com/p.png',
      ]);
      expect(ranked.first, _cjpeg);
      expect(ranked.indexOf(_cCdn), lessThan(ranked.indexOf(_cCdnHeic)));
      expect(ranked.last, _cCdnHeic);
    });

    test('a mixed post plans the same still candidates for both roles', () {
      final post = _post([
        MediaItem(type: 'image', url: _cCdn, fallbacks: const [_cCdnHeic, _cjpeg]),
        MediaItem(
          type: 'live',
          url: _cCdn,
          fallbacks: const [_cCdnHeic, _cjpeg],
          videoUrl: _cClip,
        ),
      ]);
      final planned = planFiles(post, [0, 1], (label, seq, ext) => 'f$seq.$ext');
      final still = planned.where((f) => f.isImage).toList();
      expect(still, hasLength(2));
      expect(still[0].urls, still[1].urls,
          reason: 'a Live photo still must not rank candidates differently');
      expect(still[1].urls.first, _cjpeg);
      for (final url in still[1].urls) {
        expect(mediaKindOfUrl(url), MediaContentKind.image, reason: url);
      }
      final clip = planned.singleWhere((f) => !f.isImage);
      expect(clip.urls, [_cClip]);
    });

    test('candidate labels never contain a URL, query or token', () {
      expect(candidateLabelOf(_cjpeg), 'ci:jpg');
      expect(candidateLabelOf(_cCdnHeic), 'img:heic');
      expect(candidateLabelOf(_cClip), 'video:mp4');
      for (final url in [_cjpeg, _cCdnHeic, _cClip, 'garbage']) {
        final label = candidateLabelOf(url);
        expect(label, isNot(contains('http')));
        expect(label, isNot(contains('?')));
        expect(label, isNot(contains('sign')));
        expect(label, isNot(contains('xiaohongshu')));
      }
    });
  });

  group('what the finished bytes mean for the job', () {
    test('an original-resolution HEIC is a success, never a retry', () {
      // build 41: quality first. A HEIC / AVIF still of an original candidate
      // is saved in its own container (provenance skipped); its container must
      // never make the item fall back to a preview-size candidate.
      expect(
        contentVerdictFor(
          isImage: true,
          attempts: 1,
          candidateCount: 3,
          content: detectMediaContentType(_heicStill()),
        ),
        ContentVerdict.accept,
      );
    });

    test('the last candidate HEIC is accepted, never turned into a failure', () {
      expect(
        contentVerdictFor(
          isImage: true,
          attempts: 3,
          candidateCount: 3,
          content: detectMediaContentType(_heicStill()),
        ),
        ContentVerdict.accept,
      );
      expect(
        contentVerdictFor(
          isImage: true,
          attempts: 1,
          candidateCount: 1,
          content: detectMediaContentType(_avifStill()),
        ),
        ContentVerdict.accept,
      );
    });

    test('a movie answered for an image job is a candidate error', () {
      final verdict = contentVerdictFor(
        isImage: true,
        attempts: 1,
        candidateCount: 4,
        content: detectMediaContentType(_mp4()),
      );
      expect(verdict, ContentVerdict.rejectKind);
    });

    test('a still answered for a clip job is a candidate error', () {
      expect(
        contentVerdictFor(
          isImage: false,
          attempts: 1,
          candidateCount: 1,
          content: detectMediaContentType(_jpeg()),
        ),
        ContentVerdict.rejectKind,
      );
    });

    test('unreadable headers and matching containers are kept', () {
      expect(
        contentVerdictFor(
          isImage: true,
          attempts: 1,
          candidateCount: 1,
          content: null,
        ),
        ContentVerdict.accept,
      );
      expect(
        contentVerdictFor(
          isImage: true,
          attempts: 1,
          candidateCount: 1,
          content: detectMediaContentType(_jpeg()),
        ),
        ContentVerdict.accept,
      );
    });
  });

  group('download pipeline', () {
    test('an image job that got a movie switches candidate instead of failing',
        () async {
      manager.mediaContentTypeForTesting = (path) async => sniffMediaFile(path);
      final file = await write('clip-from-image-url.jpg', _mp4());
      final job = _stillJob(urls: [_cjpeg, _cCdn]);
      manager.setBatchForTesting(_batch([job]));
      var enqueued = 0;
      manager.enqueueForTesting = (_, j) async {
        enqueued++;
        j.attempts++;
      };

      await manager.contentVerdictForTesting(
        _batch([job]),
        job,
        file.path,
        content: await sniffMediaFile(file.path),
      );

      expect(job.state, isNot(JobState.failed));
      expect(enqueued, 1, reason: 'the next candidate must be tried');
      expect(await file.exists(), isFalse, reason: 'the movie must not be kept');
      expect(logs.join('\n'), contains('role=live_still'));
      expect(logs.join('\n'), contains('result=rejected:video_container'));
    });

    test('every candidate HEIC: the still is imported, provenance skipped',
        () async {
      final file = await write('still-heic.jpg', _heicStill());
      final job = _stillJob(urls: [_cCdnHeic]);
      job.attempts = 1;
      manager.setBatchForTesting(_batch([job]));

      await manager.contentVerdictForTesting(
        _batch([job]),
        job,
        file.path,
        content: await sniffMediaFile(file.path),
      );
      // Accepted as-is: the file is still there for the import.
      expect(await file.exists(), isTrue);
      expect(job.state, isNot(JobState.failed));

      final written = await manager.embedProvenanceForTesting(
        _batch([job]),
        job,
        file.path,
      );
      expect(written, isNull);
      expect(job.provenanceSkipped, isTrue);
      expect(job.metadataNotice, isNull, reason: 'no sidecar for a HEIC still');
      expect(logs.join('\n'), contains('provenance=skipped'));

      // The album name and MIME follow the real container.
      final name = await exportNameFor(file.path, '6a29621b000000003501e972', 3);
      expect(name, '6a29621b000000003501e972_3.heic');
      expect(exportMime((await exportTypeFor(file.path))), 'image/heic');
      // History keeps the pair id, so still and clip pair into one entry.
      expect(job.isLivePhoto, isTrue);
    });

    test('a failed still is reported readably and retried alone', () async {
      final still = _stillJob(urls: [_cCdnHeic])..attempts = 1;
      final clip = _clipJob()
        ..state = JobState.done
        ..saved = true
        ..progress = 1
        ..mediaId = 'media-clip'
        ..fileBytes = 1908621;
      final batch = _batch([still, clip]);
      manager.setBatchForTesting(batch);
      final clipBefore = jsonEncode(clip.toJson());

      // The still fails at the end of its candidate list: readable message,
      // no raw exception prefix.
      await manager.contentVerdictForTesting(
        batch,
        still,
        (await write('still-mp4.jpg', _mp4())).path,
        content: await sniffMediaFile((await write('still-mp4b.jpg', _mp4())).path),
      );
      expect(still.state, JobState.failed);
      expect(still.error, '第3项实况的静态图下载失败');
      expect(still.error, isNot(contains('Bad state')));

      final reparse = _post([
        MediaItem(type: 'image', url: _cjpeg),
        MediaItem(type: 'image', url: _cjpeg),
        MediaItem(
          type: 'live',
          url: _cCdn,
          fallbacks: const [_cCdnHeic],
          videoUrl: _cClip,
        ),
      ]);
      manager.reparseForTesting = (_) async =>
          ParseOutcome(data: reparse, rawImages: const []);
      final enqueued = <DownloadJob>[];
      manager.enqueueForTesting = (_, job) async => enqueued.add(job);

      await manager.retryBatch(batch);

      expect(enqueued, [still], reason: 'only the missing half is re-downloaded');
      expect(jsonEncode(clip.toJson()), clipBefore,
          reason: 'the saved clip must stay untouched');
    });

    test('per-item save failures are readable, not raw exceptions', () {
      final still = _stillJob();
      expect(
        DownloadManager.failureTextFor(still, saving: true),
        '第3项实况的静态图保存失败',
      );
      expect(userFacingFailureReason(still..state = JobState.failed),
          isNot(contains('Bad state')));
    });

    test('retries are bounded for both transports', () {
      expect(kMaxAttemptsHardCap, lessThanOrEqualTo(6));
      final job = _stillJob(urls: [for (var i = 0; i < 9; i++) '$_cjpeg&i=$i']);
      expect(candidateCapFor(job), kMaxAttemptsHardCap);
      expect(candidateCapFor(_stillJob()), 1);
    });
  });
}
