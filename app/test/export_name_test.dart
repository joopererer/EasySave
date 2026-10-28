import 'dart:io';
import 'package:easysave/services/export_names.dart';
import 'package:easysave/services/provenance_pair.dart';
import 'package:easysave/services/saver.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const id = '7674898126922140959';
  const uuid = 'd16e3f95-5dcb-43f4-b0dd-9cea903110b6';
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('easysave/provenance_pair');
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('export_names_');
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(const MethodChannel('gal'), null);
    await dir.delete(recursive: true);
  });
  test(
    'final identity name never contains private batch or UUID components',
    () {
      expect(cleanMediaFilename(id, 1, 'jpg'), '${id}_1.jpg');
      expect(cleanMediaFilename('IG_code-1', 2, 'mp4'), 'IG_code-1_2.mp4');
      expect(
        () => cleanMediaFilename('../other', 1, 'jpg'),
        throwsArgumentError,
      );
      expect(() => cleanMediaFilename(id, 0, 'jpg'), throwsArgumentError);
    },
  );
  for (final video in [false, true]) {
    test(
      'ordinary ${video ? "video" : "image"} exports a clean final name independently of cache basename',
      () async {
        final ext = video ? 'mp4' : 'jpg';
        final source = await File(
          '../docs/provenance-spec/test-vectors/${video ? "mp4-no-xmp.mp4" : "no-metadata.jpg"}',
        ).copy('${dir.path}/batch-$uuid.$ext');
        final wanted = await exportNameFor(source.path, id, 1);
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'saveMedia');
          expect(call.arguments['filename'], '${id}_1.$ext');
          expect(call.arguments['path'], contains(uuid));
          return {
            'mediaId': '1',
            'title': wanted,
            'relativePath': 'Pictures/EasySave/',
          };
        });
        final saved = await saveToGallery(
          source.path,
          !video,
          'EasySave',
          finalName: wanted,
          nativeAndroid: true,
        );
        expect(saved.title, '${id}_1.$ext');
        expect(saved.title, isNot(contains(uuid)));
      },
    );
  }
  test(
    'C2PA pair final name is clean while sidecar remains full-media-name plus xmp',
    () async {
      final source = await File(
        '../docs/provenance-spec/test-vectors/no-metadata.jpg',
      ).copy('${dir.path}/batch-$uuid.jpg');
      await File('${source.path}.xmp').writeAsString('private staging sidecar');
      messenger.setMockMethodCallHandler(
        const MethodChannel('gal'),
        (_) async => true,
      );
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'savePair');
        expect(call.arguments['filename'], '${id}_1.jpg');
        return {
          'mediaId': '1',
          'title': '${id}_1.jpg',
          'relativePath': c2paRelativePath,
        };
      });
      expect(
        (await saveProvenancePair(source.path, finalName: '${id}_1.jpg')).title,
        '${id}_1.jpg',
      );
    },
  );
}
