import 'dart:io';
import 'package:easysave/metadata/metadata_service.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/download_provenance.dart';
import 'package:easysave/services/provenance_pair.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('easysave/provenance_pair');
  XmpProvenance provenance() => provenanceForBatchItem(
    DownloadBatch(
      batchId: 'b',
      album: 'EasySave',
      platform: 'tiktok',
      postId: '123',
      postUrl: 'https://www.tiktok.com/@/video/123',
      jobs: [],
    ),
    itemIndex: 1,
  );
  Future<File> image(String name) async {
    final jpeg = await File(
      '../docs/provenance-spec/test-vectors/no-metadata.jpg',
    ).readAsBytes();
    final bytes = [
      ...jpeg.take(2),
      0xff,
      0xeb,
      0,
      18,
      0,
      0x1c,
      0x7d,
      0x0c,
      0x80,
      0,
      0x11,
      0xea,
      0xb6,
      0x0d,
      0x17,
      0xb8,
      0x83,
      0xa6,
      0x0f,
      0x0d,
      ...jpeg.skip(2),
    ];
    return File('${dir.path}/$name.jpg').writeAsBytes(bytes);
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('c2pa_retry_');
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(const MethodChannel('gal'), null);
    await dir.delete(recursive: true);
  });
  test(
    'reproduces retained old assetId and refreshes private sidecar on retry',
    () async {
      final file = await image('retry');
      final first = provenance(), retry = provenance();
      await writeSidecarFor(file.path, first);
      await writeSidecarFor(file.path, retry);
      expect((await readSidecarFor(file.path))!.assetId, first.assetId);
      final original = await file.readAsBytes();
      expect(await prepareDownloadProvenance(file.path, retry), isTrue);
      expect((await readSidecarFor(file.path))!.assetId, retry.assetId);
      expect(await file.readAsBytes(), original);
      expect(await MetadataService.readProvenance(file.path), isNotNull);
    },
  );
  test('isolated concurrent C2PA jobs keep their own assetId', () async {
    final a = await image('a'), b = await image('b');
    final pa = provenance(), pb = provenance();
    await Future.wait([
      prepareDownloadProvenance(a.path, pa),
      prepareDownloadProvenance(b.path, pb),
    ]);
    expect((await readSidecarFor(a.path))!.assetId, pa.assetId);
    expect((await readSidecarFor(b.path))!.assetId, pb.assetId);
  });
  for (final matches in [true, false]) {
    test(
      'stored sidecar verification matches=$matches and rolls back both on mismatch',
      () async {
        final file = await image('saved');
        final expected = provenance(), wrong = provenance();
        await prepareDownloadProvenance(file.path, expected);
        final calls = <String>[];
        messenger.setMockMethodCallHandler(
          const MethodChannel('gal'),
          (_) async => true,
        );
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          if (call.method == 'savePair')
            return {
              'mediaId': '1',
              'title': 'saved.jpg',
              'relativePath': c2paRelativePath,
            };
          if (call.method == 'readSidecar')
            return buildXmpXml(matches ? expected : wrong);
          return null;
        });
        if (matches) {
          await saveProvenancePair(
            file.path,
            expectedAssetId: expected.assetId,
          );
          expect(calls, ['savePair', 'readSidecar']);
        } else {
          await expectLater(
            saveProvenancePair(file.path, expectedAssetId: expected.assetId),
            throwsA(
              isA<StateError>().having(
                (e) => e.message,
                'private-safe verification detail',
                allOf(
                  contains('文件=saved.jpg.xmp'),
                  contains('期望assetId存在=true'),
                  contains('实际assetId存在=true'),
                  contains('assetId一致=false'),
                  isNot(contains(expected.assetId)),
                  isNot(contains(wrong.assetId)),
                ),
              ),
            ),
          );
          expect(calls, ['savePair', 'readSidecar', 'deletePair']);
        }
      },
    );
  }
}
