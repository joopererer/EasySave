import 'dart:io';

import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/image_decode_probe.dart';
import 'package:easysave/services/media_content_type.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// v1.10.3: a HEIC / HEIF / AVIF original is only accepted into the album when
// the platform decoders of the device really decode it. The probe runs on the
// finished temp file, off the main thread and off photo_manager's queue, is
// bounded, and a rejection logs `result=rejected:undecodable_on_device` so the
// item continues with its next candidate instead of saving a file the album
// cannot preview.

const _postId = '6af3c278000000001c031f21';
const _postUrl = 'https://www.xiaohongshu.com/explore/$_postId';
const _heicUrl = 'https://sns-img-bd.xhscdn.com/notes_pre_post/original.heic';
const _jpegUrl =
    'https://ci.xiaohongshu.com/notes_pre_post/original?imageView2/format/jpg';

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

/// A HEIC container with the `MiHe` compatible brand of the reported samples.
Uint8List heicStillWithAlphaBrand() => Uint8List.fromList([
  ..._box('ftyp', [
    ..._fourCc('heic'), 0, 0, 0, 0,
    ..._fourCc('mif1'), ..._fourCc('MiHe'), ..._fourCc('heic'),
  ]),
  ..._box('meta', List.filled(40, 0)),
  ..._box('mdat', List.filled(64, 3)),
]);

DownloadJob _job({int attempts = 1}) {
  final job = DownloadJob(
    key: 'job-1',
    label: '图片 1',
    filename: '${_postId}_1.jpg',
    urls: [_heicUrl, _jpegUrl],
    isImage: true,
    itemIndex: 1,
  )
    ..attempts = attempts;
  return job;
}

DownloadBatch _batch(List<DownloadJob> jobs) => DownloadBatch(
  batchId: 'decode-gate',
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
  late Directory temp;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    SiteRegistry.useBuiltin();
    manager.clearBatchesForTesting();
    ImageDecodeProbe.stillGateForTesting = null;
    logs = <String>[];
    debugPrint = (message, {wrapWidth}) => logs.add(message ?? '');
    temp = await Directory.systemTemp.createTemp('decode-gate');
  });

  tearDown(() async {
    debugPrint = debugPrintThrottled;
    ImageDecodeProbe.stillGateForTesting = null;
    ImageDecodeProbe.callForTesting = null;
    manager
      ..mediaContentTypeForTesting = null
      ..clearBatchesForTesting();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<File> writeHeic() async {
    final file = File('${temp.path}/still.heic');
    await file.writeAsBytes(heicStillWithAlphaBrand());
    return file;
  }

  /// The probe answer a device would give; the decision under test is the
  /// production gate, never a stub of it.
  void answerWithDecodable(bool decodable, {String reason = 'ok'}) {
    ImageDecodeProbe.callForTesting = (method, arguments) async => {
      'decodable': decodable,
      'width': 1536,
      'height': 2560,
      'sampleWidth': decodable ? 192 : 0,
      'sampleHeight': decodable ? 320 : 0,
      'decoder': 'bitmapfactory',
      'reason': reason,
      'bytes': 78054,
    };
  }

  group('HEIC originals are gated on the device decoders', () {
    test('a sample this device cannot decode is rejected and logged', () async {
      answerWithDecodable(false, reason: 'decode_failed');
      final job = _job();
      final file = await writeHeic();
      final content = detectMediaContentType(heicStillWithAlphaBrand());
      expect(content?.extension, 'heic');
      expect(requiresDeviceDecode(content!), isTrue);

      final verdict = await manager.gatedVerdictForTesting(
        _batch([job]),
        job,
        file.path,
        content: content,
      );

      expect(verdict, ContentVerdict.rejectUndecodableOnDevice);
      final line = logs.join('\n');
      expect(line, contains('result=rejected:undecodable_on_device'));
      expect(line, contains('device_probe=undecodable'));
      expect(line, contains('device_reason=decode_failed'));
      // No path, URL, host or token ever reaches the log.
      expect(line, isNot(contains(temp.path)));
      expect(line, isNot(contains('http')));
      expect(line, isNot(contains('xhscdn')));
      expect(await file.exists(), isTrue,
          reason: 'the gate itself must not delete anything');
    });

    test('a sample this device decodes is accepted as HEIC', () async {
      answerWithDecodable(true);
      final job = _job();
      final file = await writeHeic();
      final content = detectMediaContentType(heicStillWithAlphaBrand());

      final verdict = await manager.gatedVerdictForTesting(
        _batch([job]),
        job,
        file.path,
        content: content,
      );

      expect(verdict, ContentVerdict.accept);
      final line = logs.join('\n');
      expect(line, contains('result=ok:provenance_skipped'));
      expect(line, contains('device_probe=decodable'));
      expect(line, isNot(contains('rejected:')));
    });

    test('a JPEG still is never probed', () async {
      var probed = 0;
      ImageDecodeProbe.callForTesting = (method, arguments) async {
        probed++;
        return null;
      };
      final job = _job();
      const content = MediaContentType(
        MediaContentKind.image,
        'jpg',
        'image/jpeg',
      );
      final verdict = await manager.gatedVerdictForTesting(
        _batch([job]),
        job,
        '${temp.path}/still.jpg',
        content: content,
      );
      expect(verdict, ContentVerdict.accept);
      expect(probed, 0);
      expect(requiresDeviceDecode(content), isFalse);
      expect(logs.join('\n'), isNot(contains('device_probe=')));
    });

    test('a timeout does not reject: the caller keeps its old behaviour',
        () async {
      // No channel answers at all, which is what a platform without the probe
      // looks like. Rejecting on a guess would lose every iPhone HEIC.
      ImageDecodeProbe.callForTesting = (method, arguments) async => null;
      final job = _job();
      final file = await writeHeic();
      final content = detectMediaContentType(heicStillWithAlphaBrand());

      final verdict = await manager.gatedVerdictForTesting(
        _batch([job]),
        job,
        file.path,
        content: content,
      );

      expect(verdict, ContentVerdict.accept);
      expect(logs.join('\n'), contains('device_probe=unknown'));
    });
  });

  group('jpg original candidates are tried before the HEIC original', () {
    test('every original-resolution still gains the CDN JPEG transcode', () {
      final withJpeg = withDerivedJpegOriginals([
        'https://sns-img-bd.xhscdn.com/notes_pre_post/token',
      ]);
      expect(withJpeg, [
        'https://sns-img-bd.xhscdn.com/notes_pre_post/token'
            '?imageView2/format/jpg/q/100',
        'https://sns-img-bd.xhscdn.com/notes_pre_post/token',
      ]);
      final ranked = rankStillCandidates(withJpeg);
      expect(ranked.first, contains('imageView2/format/jpg/q/100'));
      expect(stillCandidateRank(ranked.first), 0);
    });

    test('a preview derivative and an already-processed URL gain nothing', () {
      const preview =
          'https://sns-webpic-qc.xhscdn.com/202610112129/abc/notes_pre_post/still!nd_dft_wlteh_webp_3';
      const processed =
          'https://ci.xiaohongshu.com/notes_pre_post/token?imageView2/format/jpg';
      expect(derivedJpegOriginal(preview), isNull);
      expect(derivedJpegOriginal(processed), isNull);
      expect(derivedJpegOriginal('https://sns-video-v27.xhscdn.com/stream/x.mp4'),
          isNull);
      expect(withDerivedJpegOriginals([preview]), [preview]);
    });

    test('the derived candidate keeps the token, only the query is added', () {
      const original = 'https://sns-img-bd.xhscdn.com/notes_pre_post/token';
      final derived = derivedJpegOriginal(original)!;
      expect(Uri.parse(derived).path, Uri.parse(original).path);
      expect(Uri.parse(derived).host, Uri.parse(original).host);
      expect(Uri.parse(derived).query, 'imageView2/format/jpg/q/100');
    });
  });
}
