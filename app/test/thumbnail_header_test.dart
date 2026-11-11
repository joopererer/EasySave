import 'dart:io';
import 'dart:typed_data';
import 'dart:isolate';
import 'package:easysave/services/shared_preview_cache.dart';
import 'package:easysave/services/thumbnail_header.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'cache file writer rejects producer isolate and publishes complete bytes in worker',
    () async {
      final bytes = File(
        'test/fixtures/build24/portrait.jpeg',
      ).readAsBytesSync();
      final input = (
        root: 'build/build24-worker-cache',
        key: 'a' * 64,
        bytes: bytes,
        origin: Isolate.current.controlPort,
      );
      expect(() => writeThumbnailFile(input), throwsStateError);
      final written = await compute(writeThumbnailFile, input);
      expect(await File(written.path).readAsBytes(), bytes);
      expect(
        (await File(written.path).lastModified()).isAfter(DateTime.now()),
        isTrue,
      );
      expect(
        Directory(input.root).listSync().where((f) => f.path.endsWith('.tmp')),
        isEmpty,
      );
    },
  );
  for (final format in ['jpeg', 'png', 'webp']) {
    test(
      '$format header accepts complete file and rejects every truncated prefix',
      () async {
        final bytes = File(
          'test/fixtures/build24/portrait.$format',
        ).readAsBytesSync();
        await compute(validateThumbnailHeader, bytes);
        for (var length = 0; length < bytes.length; length++) {
          expect(
            () => validateThumbnailHeader(
              Uint8List.sublistView(bytes, 0, length),
            ),
            throwsFormatException,
            reason: '$format length=$length',
          );
        }
      },
    );
  }
}
