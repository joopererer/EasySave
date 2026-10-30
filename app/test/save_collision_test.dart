import 'dart:io';

import 'package:easysave/metadata/metadata_service.dart';
import 'package:easysave/services/save_collision.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

XmpProvenance origin(String assetId) => XmpProvenance(
  schema: 'easysave',
  assetId: assetId,
  capturedAt: DateTime.utc(2026, 10, 30),
  capturedBy: 'EasySave/1.10.0',
  metadataDate: DateTime.utc(2026, 10, 30),
  platform: 'xhs',
  sourceId: 'post',
  sourceUrl: 'https://www.xiaohongshu.com/explore/post',
  itemIndex: 1,
  itemCount: 1,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final (label, extension, pair) in [
    ('image', 'jpg', false),
    ('video', 'mp4', false),
    ('C2PA image', 'png', true),
  ]) {
    test(
      '$label reuses same-origin target and removes staging files',
      () async {
        final dir = await Directory.systemTemp.createTemp('save_collision_');
        addTearDown(() => dir.delete(recursive: true));
        final temp = File('${dir.path}/input.$extension')
          ..writeAsBytesSync([1]);
        File('${temp.path}.xmp').writeAsStringSync('sidecar');
        var saved = false;
        final expected = origin('new-asset');
        final result = await saveWithConflictHandling(
          filename: 'post_1.$extension',
          tempPath: temp.path,
          album: 'EasySave',
          pair: pair,
          expected: expected,
          inspect: (_) async => {
            'mediaId': '42',
            'title': 'post_1.$extension',
            'relativePath': pair ? 'Download/EasySave/' : 'Pictures/EasySave/',
          },
          readOrigin: (_) async => expected.copyWith(assetId: 'saved-asset'),
          save: (_) async {
            saved = true;
            throw StateError('must not save again');
          },
        );
        expect(saved, isFalse);
        expect(result.saved.mediaId, '42');
        expect(result.reusedAssetId, 'saved-asset');
        expect(await temp.exists(), isFalse);
        expect(await File('${temp.path}.xmp').exists(), isFalse);
      },
    );

    test('$label changes filename for unrelated target', () async {
      final expected = origin('new-asset');
      final names = <String>[];
      final result = await saveWithConflictHandling(
        filename: 'post_1.$extension',
        tempPath: 'unused',
        album: 'EasySave',
        pair: pair,
        expected: expected,
        inspect: (name) async => name == 'post_1.$extension'
            ? {
                'mediaId': 'old',
                'title': name,
                'relativePath': 'Pictures/EasySave/',
              }
            : null,
        readOrigin: (_) async => expected.copyWith(itemIndex: 2),
        save: (name) async {
          names.add(name);
          return (
            mediaId: 'new',
            title: name,
            relativePath: pair ? 'Download/EasySave/' : 'Pictures/EasySave/',
          );
        },
      );
      expect(names, ['post-copy2_1.$extension']);
      if (pair) expect('${names.single}.xmp', 'post-copy2_1.png.xmp');
      expect(result.saved.title, names.single);
      expect(result.reusedAssetId, isNull);
    });
  }

  test('concurrent same-origin save collision is recovered', () async {
    final expected = origin('new-asset');
    var lookups = 0;
    final result = await saveWithConflictHandling(
      filename: 'post_1.jpg',
      tempPath: 'unused',
      album: 'EasySave',
      pair: false,
      expected: expected,
      inspect: (_) async => ++lookups == 1
          ? null
          : {
              'mediaId': '42',
              'title': 'post_1.jpg',
              'relativePath': 'Pictures/EasySave/',
            },
      readOrigin: (_) async => expected,
      save: (_) async => throw PlatformException(
        code: 'provenance_pair',
        message:
            'saveMedia: IllegalStateException: Target filename already exists',
      ),
    );
    expect(result.saved.mediaId, '42');
  });

  test('provider rename race retries with clean suffix', () async {
    final savedNames = <String>[];
    final result = await saveWithConflictHandling(
      filename: 'post_1.mp4',
      tempPath: 'unused',
      album: 'EasySave',
      pair: false,
      expected: origin('new-asset'),
      inspect: (_) async => null,
      save: (name) async {
        savedNames.add(name);
        if (savedNames.length == 1) {
          throw PlatformException(
            code: 'provenance_pair',
            message: 'Provider changed final filename',
          );
        }
        return (mediaId: '99', title: name, relativePath: 'Pictures/EasySave/');
      },
    );
    expect(savedNames, ['post_1.mp4', 'post-copy2_1.mp4']);
    expect(result.saved.title, 'post-copy2_1.mp4');
  });
}
