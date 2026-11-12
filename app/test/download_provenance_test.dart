import 'dart:io';
import 'dart:typed_data';
import 'package:easysave/metadata/metadata_service.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/download_provenance.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final batch = DownloadBatch(batchId: 'test', album: 'EasySave', platform: 'tiktok',
    postId: '123456789', postUrl: 'https://www.tiktok.com/@/video/123456789',
    jobs: [], postItemCount: 2, aiLabel: 'Creator labeled as AI-generated', aiLabelSource: 'author');
  final provenance = provenanceForBatchItem(batch, itemIndex: 1);
  late Directory directory;
  setUp(() async { directory = await Directory.systemTemp.createTemp('download_xmp_'); });
  tearDown(() async { MetadataService.embedOverride = null; await directory.delete(recursive: true); });

  test('downloaded TikTok photo writes platform and verbatim AI metadata', () async {
    final bytes = await File('../docs/provenance-spec/test-vectors/no-metadata.jpg').readAsBytes();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async { request.response.add(bytes); await request.response.close(); });
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final response = await (await client.getUrl(Uri.parse('http://127.0.0.1:${server.port}/photo'))).close();
    final file = File('${directory.path}/photo.jpg');
    await response.pipe(file.openWrite());
    expect(await prepareDownloadProvenance(file.path, provenance), isFalse);
    final read = await MetadataService.readProvenance(file.path);
    expect(read?.platform, 'tiktok');
    expect(read?.aiLabel, batch.aiLabel);
    expect(read?.aiLabelSource, 'author');
    expect(read?.digitalSourceType, 'http://cv.iptc.org/newscodes/digitalsourcetype/compositeWithTrainedAlgorithmicMedia');
  });

  test('C2PA photo bytes remain intact and full-name sidecar contains AI fields', () async {
    final jpeg = await File('../docs/provenance-spec/test-vectors/no-metadata.jpg').readAsBytes();
    // Minimal synthetic APP11 C2PA marker: no real post/account data.
    final bytes = [...jpeg.take(2), 0xff, 0xeb, 0, 18,
      0, 0x1c, 0x7d, 0x0c, 0x80, 0, 0x11, 0xea, 0xb6, 0x0d, 0x17, 0xb8, 0x83, 0xa6, 0x0f, 0x0d,
      ...jpeg.skip(2)];
    final file = await File('${directory.path}/photo.jpg').writeAsBytes(bytes);
    expect(await prepareDownloadProvenance(file.path, provenance), isTrue);
    expect(await file.readAsBytes(), bytes);
    expect(await File('${file.path}.xmp').exists(), isTrue);
    final read = await readSidecarFor(file.path);
    expect(read?.platform, 'tiktok');
    expect(read?.aiLabel, batch.aiLabel);
    expect(read?.aiLabelSource, 'author');
    expect(read?.digitalSourceType, provenance.digitalSourceType);
  });

  test('unsupported image is an explicit user-visible failure', () async {
    final file = await File('${directory.path}/photo.avif').writeAsString('unsupported test container');
    await expectLater(prepareDownloadProvenance(file.path, provenance),
      throwsA(isA<StateError>().having((e) => e.message, 'message', '该格式无法写入来源信息')));
  });

  test('a HEIC still is never given an MP4 XMP box', () async {
    // A Xiaohongshu Live photo still: HEIC brand, top-level meta and mdat.
    Uint8List box(String type, List<int> body) {
      final size = 8 + body.length;
      return Uint8List.fromList([
        (size >> 24) & 0xff, (size >> 16) & 0xff, (size >> 8) & 0xff, size & 0xff,
        ...type.codeUnits, ...body,
      ]);
    }

    Uint8List fourCc(String type) => Uint8List.fromList(type.codeUnits);
    final bytes = Uint8List.fromList([
      ...box('ftyp', [...fourCc('heic'), 0, 0, 0, 0, ...fourCc('mif1'), ...fourCc('heic')]),
      ...box('meta', List.filled(40, 0)),
      ...box('mdat', List.filled(64, 3)),
    ]);
    final file = await File('${directory.path}/still.heic').writeAsBytes(bytes);
    await expectLater(prepareDownloadProvenance(file.path, provenance),
      throwsA(isA<StateError>().having((e) => e.message, 'message', '该格式无法写入来源信息')));
    expect(await file.readAsBytes(), bytes, reason: 'the still must stay byte-identical');
    for (final chunk in ['uuid', 'XMP']) {
      expect(String.fromCharCodes(bytes).contains(chunk), isFalse);
    }
  });

  test('write success without persisted metadata fails verification', () async {
    final file = await File('../docs/provenance-spec/test-vectors/no-metadata.jpg')
        .copy('${directory.path}/photo.jpg');
    MetadataService.embedOverride = ({required filePath, required provenance,
      checkC2pa = true, mp4WriteMode = Mp4WriteMode.rewrite}) async => const EmbedResult(success: true);
    await expectLater(prepareDownloadProvenance(file.path, provenance),
      throwsA(isA<StateError>().having((e) => e.message, 'message', contains('实际assetId存在=false'))));
  });
}
