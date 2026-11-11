import 'dart:io';
import 'dart:typed_data';

import 'package:easysave/core/models.dart';
import 'package:easysave/services/download_claims.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/image_dimensions.dart';
import 'package:easysave/services/parse_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _token = 'notes_pre_post/1040g3k83264voo1al0dg5o2e1l408pfcf1dl208';
const _original = 'https://sns-img-bd.xhscdn.com/$_token';
const _jpeg = 'https://ci.xiaohongshu.com/$_token?imageView2/format/jpg';
const _preview =
    'https://sns-webpic-qc.xhscdn.com/202610112129/a657f0bce4b0d577975cf2d1df487c06/$_token!nd_prv_wlteh_webp_3';
const _dft =
    'https://sns-webpic-qc.xhscdn.com/202610112129/eb1fb79a62c72f9dbe14dd2909e2d83c/$_token!nd_dft_wlteh_webp_3';
const _ci = 'https://ci.xiaohongshu.com/$_token';

Uint8List _jpegBytes(int width, int height) => Uint8List.fromList([
  0xFF, 0xD8,
  // APP1 segment (e.g. EXIF/XMP) before the frame.
  0xFF, 0xE1, 0x00, 0x08, 0x45, 0x78, 0x69, 0x66, 0x00, 0x00,
  // SOF0: length 17, precision 8, height, width, 3 components.
  0xFF, 0xC0, 0x00, 0x11, 0x08, height >> 8, height & 0xFF, width >> 8, width & 0xFF,
  0x03, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1,
  0xFF, 0xD9,
]);

Uint8List _pngBytes(int width, int height) {
  final b = BytesBuilder()
    ..add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13])
    ..add('IHDR'.codeUnits);
  final dims = ByteData(8)
    ..setUint32(0, width)
    ..setUint32(4, height);
  b
    ..add(dims.buffer.asUint8List())
    ..add([8, 6, 0, 0, 0, 0, 0, 0, 0]);
  return b.toBytes();
}

Uint8List _webpVp8x(int width, int height) {
  final b = BytesBuilder()
    ..add('RIFF'.codeUnits)
    ..add([30, 0, 0, 0])
    ..add('WEBP'.codeUnits)
    ..add('VP8X'.codeUnits)
    ..add([10, 0, 0, 0, 0, 0, 0, 0]);
  int w = width - 1, h = height - 1;
  b.add([w & 0xFF, (w >> 8) & 0xFF, (w >> 16) & 0xFF, h & 0xFF, (h >> 8) & 0xFF, (h >> 16) & 0xFF]);
  return b.toBytes();
}

DownloadJob _imageJob({int urls = 4}) => DownloadJob(
  key: 'job-1',
  label: '图片 1',
  filename: 'x.jpg',
  urls: [for (var i = 0; i < urls; i++) 'https://ci.xiaohongshu.com/candidate-$i'],
  isImage: true,
  itemIndex: 1,
)
  ..expectedWidth = 1290
  ..expectedHeight = 1608;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('image header size', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('easysave_dims'));
    tearDown(() => dir.delete(recursive: true));

    Future<ImageSize?> sizeOf(Uint8List bytes, String name) async {
      final f = File('${dir.path}/$name')..writeAsBytesSync(bytes);
      return readImageSize(f.path);
    }

    test('reads JPEG, PNG and WebP sizes without decoding', () async {
      expect(await sizeOf(_jpegBytes(1290, 1608), 'a.jpg'), (width: 1290, height: 1608));
      expect(await sizeOf(_pngBytes(400, 300), 'b.png'), (width: 400, height: 300));
      expect(await sizeOf(_webpVp8x(1080, 1350), 'c.webp'), (width: 1080, height: 1350));
      expect(await sizeOf(Uint8List.fromList('not an image at all'.codeUnits), 'd.bin'), isNull);
    });

    test('low resolution means a long side below 80 % of the declared one', () {
      expect(isLowResolution(1290, 1608, 1290, 1608), isFalse);
      expect(isLowResolution(1290, 1608, 1080, 1350), isFalse); // 84 %
      expect(isLowResolution(1290, 1608, 1608, 1290), isFalse); // rotated
      expect(isLowResolution(1290, 1608, 576, 720), isTrue); // preview size
    });
  });

  test('XHS images download in the parser order, without the preview', () {
    final post = ParsedPost(
      platform: 'xhs',
      id: 'p',
      url: 'https://www.xiaohongshu.com/explore/p',
      author: PostAuthor(),
      items: [
        MediaItem(
          type: 'image',
          url: _original,
          width: 1290,
          height: 1608,
          fallbacks: const [_jpeg, _preview, _dft, _ci],
          downloadOrder: const [_jpeg, _original, _ci, _dft],
        ),
      ],
    );
    final planned = planFiles(post, [0], (l, s, e) => 'f$s.$e').single;
    expect(planned.urls, [_jpeg, _original, _ci, _dft]);
    expect(planned.urls, isNot(contains(_preview)));
    expect((planned.expectedWidth, planned.expectedHeight), (1290, 1608));
    // The App keeps the order when items round-trip through history JSON.
    final reread = MediaItem.fromJson(post.items.single.toJson());
    expect(reread.downloadOrder, [_jpeg, _original, _ci, _dft]);
    expect(MediaItem.fromJson({'type': 'image', 'url': _original}).toJson()
        .containsKey('downloadOrder'), isFalse);
  });

  group('low-resolution retry', () {
    final manager = DownloadManager.instance;
    late Directory temp;
    final logs = <String>[];

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      HistoryDb.resetInstanceForTesting();
      await HistoryDb.instance(dbPath: ':memory:');
      manager.clearBatchesForTesting();
      temp = await Directory.systemTemp.createTemp('easysave_lowres');
      manager.tempRootForTesting = () async => temp;
      logs.clear();
      debugPrint = (message, {wrapWidth}) => logs.add(message ?? '');
    });

    tearDown(() async {
      debugPrint = debugPrintThrottled;
      manager
        ..imageSizeForTesting = null
        ..enqueueForTesting = null
        ..tempRootForTesting = null;
      await DownloadClaims.release('lowres');
      manager.clearBatchesForTesting();
      HistoryDb.resetInstanceForTesting();
      await temp.delete(recursive: true);
    });

    DownloadBatch batchFor(DownloadJob job) => DownloadBatch(
      batchId: 'lowres',
      album: 'EasySave',
      postUrl: 'https://www.xiaohongshu.com/explore/p',
      platform: 'xhs',
      postId: 'p',
      jobs: [job],
    );

    File download(String name) =>
        File('${temp.path}/$name')..writeAsBytesSync(Uint8List(16));

    test('a too-small file is set aside and the next candidate is fetched',
        () async {
      final job = _imageJob()..attempts = 1;
      final batch = batchFor(job);
      manager.setBatchForTesting(batch);
      var enqueued = 0;
      manager.enqueueForTesting = (_, j) async {
        enqueued++;
        j.attempts++;
      };
      manager.imageSizeForTesting = (_) async => (width: 576, height: 720);
      final first = download('first.jpg');

      final result = await manager.checkResolutionForTesting(batch, job, first.path);
      expect(result.retry, isTrue);
      expect(enqueued, 1);
      expect(await first.exists(), isFalse);
      expect(job.lowResPath, isNotNull);
      expect(await File(job.lowResPath!).exists(), isTrue);
      expect(logs.any((l) => l.contains('reason=low_resolution') &&
          l.contains('expected=1290x1608') && l.contains('actual=576x720')), isTrue);

      // The next candidate is full size: the kept copy is dropped.
      final kept = job.lowResPath!;
      manager.imageSizeForTesting = (_) async => (width: 1290, height: 1608);
      final second = download('second.jpg');
      final ok = await manager.checkResolutionForTesting(batch, job, second.path);
      expect(ok, (retry: false, path: second.path));
      expect(job.lowResPath, isNull);
      expect(job.notOriginal, isFalse);
      expect(await File(kept).exists(), isFalse);
    });

    test('when every candidate is small the largest is kept as 非原图', () async {
      final job = _imageJob(urls: 2)..attempts = 1;
      final batch = batchFor(job);
      manager.setBatchForTesting(batch);
      manager.enqueueForTesting = (_, j) async => j.attempts++;
      manager.imageSizeForTesting = (_) async => (width: 864, height: 1080);
      expect((await manager.checkResolutionForTesting(batch, job, download('a.jpg').path)).retry,
          isTrue);
      final larger = job.lowResPath!;

      manager.imageSizeForTesting = (_) async => (width: 576, height: 720);
      final last = await manager.checkResolutionForTesting(batch, job, download('b.jpg').path);
      expect(last.retry, isFalse);
      expect(last.path, larger, reason: 'the larger earlier copy wins');
      expect(job.notOriginal, isTrue);
    });

    test('images without a declared size are not checked', () async {
      final job = _imageJob()
        ..expectedWidth = null
        ..attempts = 1;
      manager.imageSizeForTesting = (_) async => fail('must not read the size');
      final file = download('c.jpg');
      final result = await manager.checkResolutionForTesting(batchFor(job), job, file.path);
      expect(result, (retry: false, path: file.path));
    });
  });

  test('XhsImageProbe lines carry field names and variants only', () {
    final lines = formatParserProbe({
      'tag': 'XhsStreamProbe',
      'streams': [],
      'images': [
        {
          'index': 1, 'width': 1290, 'height': 1608,
          'fields': ['urlDefault', 'infoList'], 'scenes': ['WB_PRV', 'WB_DFT'],
          'candidates': ['jpeg', 'original', 'default'], 'selected': 'jpeg',
        },
      ],
    });
    expect(lines, [
      (
        'XhsImageProbe',
        'image=1/1 declared=1290x1608 fields=urlDefault|infoList '
            'scenes=WB_PRV|WB_DFT candidates=jpeg|original|default selected=jpeg',
      ),
    ]);
  });
}
