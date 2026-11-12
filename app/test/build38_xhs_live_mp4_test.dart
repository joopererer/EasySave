import 'dart:io';
import 'package:easysave/core/models.dart';
import 'package:easysave/services/download_claims.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/export_names.dart';
import 'package:easysave/services/media_content_type.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

// v1.10.1: a Live photo's motion clip must only ever be fetched from a video
// URL, and a finished file whose own bytes contradict the plan is discarded.

const _stillJpeg = 'https://ci.xiaohongshu.com/notes_pre_post/1040g3k8live?imageView2/format/jpg';
const _stillHeic = 'https://sns-img-bd.xhscdn.com/notes_pre_post/1040g3k8live';
const _clip = 'https://sns-video-v27.xhscdn.com/stream/1/10/19/01ea342f_19.mp4?sign=x';

ParsedPost _post(List<MediaItem> items) => ParsedPost(
  platform: 'xhs',
  id: '6ae9d62b000000000f026e9d',
  url: 'https://www.xiaohongshu.com/explore/6ae9d62b000000000f026e9d',
  author: PostAuthor(name: 'a', id: 'b'),
  items: items,
);

Uint8List _fourCc(String type) => Uint8List.fromList(type.codeUnits);

Uint8List _box(String type, List<int> body) {
  final size = 8 + body.length;
  return Uint8List.fromList([
    (size >> 24) & 0xff, (size >> 16) & 0xff, (size >> 8) & 0xff, size & 0xff,
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

Uint8List _mp4({bool withMoov = true}) => Uint8List.fromList([
  ..._ftyp('isom', ['isom', 'mp41']),
  if (withMoov) ..._box('moov', List.filled(120, 0)),
  ..._box('mdat', List.filled(256, 7)),
]);

Uint8List _mov() => Uint8List.fromList([
  ..._ftyp('qt  ', ['qt  ']),
  ..._box('moov', List.filled(80, 0)),
  ..._box('mdat', List.filled(128, 1)),
]);

Uint8List _jpeg() => Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0, 16, ...List.filled(32, 0)]);

DownloadJob _liveVideoJob({int urls = 1}) => DownloadJob(
  key: 'job-video',
  label: 'Live 1',
  filename: '6ae9d62b000000000f026e9d_1.mp4',
  urls: [for (var i = 0; i < urls; i++) '$_clip&try=$i'],
  isImage: false,
  itemIndex: 1,
  isLivePhoto: true,
);

DownloadJob _imageJob({int urls = 1}) => DownloadJob(
  key: 'job-image',
  label: 'Live 1',
  filename: '6ae9d62b000000000f026e9d_1.jpg',
  urls: [for (var i = 0; i < urls; i++) '$_stillJpeg&try=$i'],
  isImage: true,
  itemIndex: 1,
  isLivePhoto: true,
);

void main() {
  group('download plan keeps each file to its own media kind', () {
    test('a Live item fetches its clip from the video URL only', () {
      final post = _post([
        MediaItem(
          type: 'live',
          url: _stillHeic,
          videoUrl: _clip,
          fallbacks: const [_stillJpeg, _stillHeic],
        ),
      ]);
      final planned = planFiles(post, [0], (label, seq, ext) => 'f$seq.$ext');
      expect(planned.length, 2);

      final image = planned[0];
      expect(image.isImage, isTrue);
      expect(image.isLivePhoto, isTrue);
      expect(image.urls, contains(_stillJpeg));
      for (final url in image.urls) {
        expect(mediaKindOfUrl(url), MediaContentKind.image, reason: url);
      }

      final video = planned[1];
      expect(video.isImage, isFalse);
      expect(video.isLivePhoto, isTrue);
      expect(video.urls, [_clip]);
    });

    test('a polluted fallback list never puts image URLs in the video file', () {
      final post = _post([
        MediaItem(
          type: 'video',
          url: _clip,
          fallbacks: const [_stillJpeg, '$_clip&backup=1', _stillHeic],
        ),
      ]);
      final planned = planFiles(post, [0], (label, seq, ext) => 'f$seq.$ext').single;
      expect(planned.isImage, isFalse);
      expect(planned.urls, [_clip, '$_clip&backup=1']);
      for (final url in planned.urls) {
        expect(mediaKindOfUrl(url), MediaContentKind.video, reason: url);
      }
    });

    test('a still-image item never carries a motion clip', () {
      final post = _post([
        MediaItem(type: 'image', url: _stillHeic, fallbacks: const [_clip, _stillJpeg]),
      ]);
      final planned = planFiles(post, [0], (label, seq, ext) => 'f$seq.$ext').single;
      expect(planned.isImage, isTrue);
      expect(planned.urls, isNot(contains(_clip)));
      expect(planned.urls, contains(_stillJpeg));
    });
  });

  group('finished file content check', () {
    final manager = DownloadManager.instance;
    late Directory temp;
    late List<String> logs;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('easysave_content_check');
      logs = <String>[];
      debugPrint = (message, {wrapWidth}) => logs.add(message ?? '');
    });

    tearDown(() async {
      debugPrint = debugPrintThrottled;
      manager
        ..enqueueForTesting = null
        ..mediaContentTypeForTesting = null;
      await DownloadClaims.release('content');
      manager.clearBatchesForTesting();
      await temp.delete(recursive: true);
    });

    Future<File> write(String name, Uint8List bytes) async =>
        File('${temp.path}/$name').writeAsBytes(bytes);

    DownloadBatch batchFor(DownloadJob job) => DownloadBatch(
      batchId: 'content',
      album: 'EasySave',
      postUrl: 'https://www.xiaohongshu.com/explore/p',
      platform: 'xhs',
      postId: 'p',
      jobs: [job],
    );

    test('a HEIC still downloaded for a video job is rejected', () async {
      final file = await write('heic.mp4', _heicStill());
      final wrong = await manager.wrongContentForTesting(_liveVideoJob(), file.path);
      expect(wrong, isNotNull);
      expect(wrong!.isImage, isTrue);
      expect(wrong.extension, 'heic');
    });

    test('a real movie passes, one without moov does not', () async {
      expect(await manager.wrongContentForTesting(
          _liveVideoJob(), (await write('ok.mp4', _mp4())).path), isNull);
      expect(await manager.wrongContentForTesting(
          _liveVideoJob(), (await write('nomoov.mp4', _mp4(withMoov: false))).path), isNotNull);
    });

    test('a movie downloaded for an image job is rejected', () async {
      final file = await write('clip.jpg', _mp4());
      expect(await manager.wrongContentForTesting(_imageJob(), file.path), isNotNull);
      expect(await manager.wrongContentForTesting(
          _imageJob(), (await write('still.jpg', _jpeg())).path), isNull);
    });

    test('an unreadable header is kept, never treated as a mismatch', () async {
      expect(await manager.wrongContentForTesting(_liveVideoJob(), '${temp.path}/missing'), isNull);
      final file = await write('blob.mp4', Uint8List.fromList('unknown container'.codeUnits));
      expect(await manager.wrongContentForTesting(_liveVideoJob(), file.path), isNull);
    });

    test('the wrong file is discarded and the next candidate is tried', () async {
      final job = _liveVideoJob(urls: 2)..attempts = 1;
      final batch = batchFor(job);
      manager.setBatchForTesting(batch);
      var enqueued = 0;
      manager.enqueueForTesting = (_, j) async {
        enqueued++;
        j.attempts++;
      };
      final file = await write('first.mp4', _heicStill());

      await manager.discardWrongContentForTesting(batch, job, file.path);
      expect(await file.exists(), isFalse, reason: 'the HEIC must not be saved');
      expect(enqueued, 1);
      expect(job.state, JobState.queued);
    });

    test('the last candidate fails the job instead of saving the still', () async {
      final job = _liveVideoJob()..attempts = 1;
      final batch = batchFor(job);
      manager.setBatchForTesting(batch);
      manager.enqueueForTesting = (_, j) async => fail('no candidate is left');
      final file = await write('only.mp4', _heicStill());

      await manager.discardWrongContentForTesting(batch, job, file.path);
      expect(await file.exists(), isFalse);
      expect(job.state, JobState.failed);
      expect(job.saved, isFalse);
      expect(job.error, '下载到的文件不是视频，已跳过');
    });
  });

  group('album name and MIME follow the bytes', () {
    late Directory temp;
    setUp(() async {
      temp = await Directory.systemTemp.createTemp('easysave_export_name');
    });
    tearDown(() => temp.delete(recursive: true));

    Future<({String name, MediaContentType type})> exportFor(
        String file, Uint8List bytes) async {
      final path = (await File('${temp.path}/$file').writeAsBytes(bytes)).path;
      return (name: await exportNameFor(path, 'abc123', 3), type: await exportTypeFor(path));
    }

    test('a HEIC still keeps its own extension and MIME', () async {
      final result = await exportFor('download.mp4', _heicStill());
      expect(result.name, 'abc123_3.heic');
      expect(exportMime(result.type), 'image/heic');
    });

    test('ordinary images and movies keep theirs', () async {
      final image = await exportFor('download.jpg', _jpeg());
      expect(image.name, 'abc123_3.jpg');
      expect(exportMime(image.type), 'image/jpeg');

      final video = await exportFor('download.mp4', _mp4());
      expect(video.name, 'abc123_3.mp4');
      expect(exportMime(video.type), 'video/mp4');

      final quicktime = await exportFor('download.mov', _mov());
      expect(quicktime.name, 'abc123_3.mov');
      expect(exportMime(quicktime.type), 'video/quicktime');
    });
  });
}
