// Copyright 2026 EasySave. All rights reserved.
// XMP read/write tests

import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:easysave/metadata/xmp_model.dart';
import 'package:easysave/metadata/xmp_jpeg.dart';
import 'package:easysave/metadata/xmp_png.dart';

void main() {
  group('XMP Model', () {
    test('toJson/fromJson roundtrip', () {
      final xmp = XmpProvenance(
        schema: '0.1',
        assetId: 'test-asset-id',
        capturedAt: DateTime.utc(2026, 10, 20, 10, 30),
        capturedBy: 'EasySave v1.7',
        metadataDate: DateTime.utc(2026, 10, 20, 10, 31),
        sourceUrl: 'https://www.xiaohongshu.com/explore/test123',
        platform: 'xiaohongshu',
        sourceId: 'test123',
        itemIndex: 0,
        itemCount: 3,
        title: 'Test Title',
        creators: ['Test Author'],
        description: 'Test Description',
        credit: 'Test Author',
      );

      final json = xmp.toJson();
      final restored = XmpProvenance.fromJson(json);

      expect(restored.assetId, xmp.assetId);
      expect(restored.platform, xmp.platform);
      expect(restored.title, xmp.title);
      expect(restored.capturedAt, xmp.capturedAt);
    });
  });

  group('JPEG XMP', () {
    test('write and read XMP', () {
      // Minimal valid JPEG: SOI + APP0 + SOF0 + SOS + EOI
      final minimalJpeg = Uint8List.fromList([
        0xFF, 0xD8, // SOI
        0xFF, 0xE0, 0x00, 0x10, // APP0 length=16
        ...List.filled(14, 0), // APP0 data
        0xFF, 0xC0, 0x00, 0x0B, // SOF0 length=11
        ...List.filled(9, 0), // SOF0 data
        0xFF, 0xDA, 0x00, 0x08, // SOS length=8
        ...List.filled(6, 0), // SOS data
        0xFF, 0xD9, // EOI
      ]);

      final xmp = XmpProvenance(
        schema: '0.1',
        assetId: 'jpeg-test',
        capturedAt: DateTime.utc(2026, 10, 20),
        capturedBy: 'EasySave',
        metadataDate: DateTime.utc(2026, 10, 20),
        sourceUrl: 'https://example.com/test',
        platform: 'web',
        sourceId: 'test',
      );

      final withXmp = writeJpegXmp(minimalJpeg, xmp);
      final read = readJpegXmp(withXmp);

      expect(read, isNotNull);
      expect(read!.assetId, 'jpeg-test');
      expect(read.platform, 'web');
    });
  });

  group('PNG XMP', () {
    test('write and read XMP', () {
      // Minimal valid PNG
      final minimalPng = Uint8List.fromList([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature
        0x00, 0x00, 0x00, 0x0D, // IHDR length=13
        0x49, 0x48, 0x44, 0x52, // "IHDR"
        0x00, 0x00, 0x00, 0x01, // width=1
        0x00, 0x00, 0x00, 0x01, // height=1
        0x08, 0x02, 0x00, 0x00, 0x00, // bit depth=8, color=RGB, etc.
        0x90, 0x77, 0x53, 0xDE, // CRC
        0x00, 0x00, 0x00, 0x00, // IEND length=0
        0x49, 0x45, 0x4E, 0x44, // "IEND"
        0xAE, 0x42, 0x60, 0x82, // CRC
      ]);

      final xmp = XmpProvenance(
        schema: '0.1',
        assetId: 'png-test',
        capturedAt: DateTime.utc(2026, 10, 20),
        capturedBy: 'EasySave',
        metadataDate: DateTime.utc(2026, 10, 20),
        sourceUrl: 'https://example.com/test',
        platform: 'web',
        sourceId: 'test',
      );

      final withXmp = writePngXmp(minimalPng, xmp);
      final read = readPngXmp(withXmp);

      expect(read, isNotNull);
      expect(read!.assetId, 'png-test');
      expect(read.platform, 'web');
    });
  });
}
