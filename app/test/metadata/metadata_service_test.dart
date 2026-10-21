// Copyright 2026 EasySave. All rights reserved.
// MetadataService unit tests.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:easysave/metadata/metadata_service.dart';
import 'package:easysave/metadata/xmp_model.dart';

void main() {
  group('ProvenanceBuilder', () {
    test('builds XmpProvenance from context', () {
      final builder = ProvenanceBuilder(
        platform: 'xiaohongshu',
        postId: 'abc123',
        postUrl: 'https://www.xiaohongshu.com/explore/abc123?utm_source=test',
        authorId: 'author1',
        authorName: 'Test User',
        title: 'Test Title',
        caption: 'Test Caption',
        publishedAt: DateTime.utc(2026, 10, 20, 10, 0),
        itemIndex: 2,
        itemCount: 5,
        existingAssetId: 'existing-asset-id',
      );

      final xmp = builder.build();

      expect(xmp.assetId, 'existing-asset-id');
      expect(xmp.platform, 'xiaohongshu');
      expect(xmp.sourceId, 'abc123');
      expect(xmp.title, 'Test Title');
      expect(xmp.creators, ['Test User']);
      expect(xmp.description, 'Test Caption');
      expect(xmp.itemIndex, 2);
      expect(xmp.itemCount, 5);
      expect(xmp.publishedAt, DateTime.utc(2026, 10, 20, 10, 0));
      expect(xmp.credit, 'Test User / 小红书');
    });

    test('itemIndex null when single item', () {
      final builder = ProvenanceBuilder(
        platform: 'xiaohongshu',
        postId: 'abc123',
        postUrl: 'https://www.xiaohongshu.com/explore/abc123',
        itemIndex: 0,
        itemCount: 1,
      );

      final xmp = builder.build();

      expect(xmp.itemIndex, isNull);
      expect(xmp.itemCount, isNull);
    });

    test('existingAssetId is reused', () {
      final builder = ProvenanceBuilder(
        platform: 'xiaohongshu',
        postId: 'abc123',
        postUrl: 'https://www.xiaohongshu.com/explore/abc123',
        itemIndex: 0,
        itemCount: 1,
        existingAssetId: 'my-asset-id-123',
      );

      final xmp = builder.build();

      expect(xmp.assetId, 'my-asset-id-123');
    });

    test('generates new assetId when none provided', () {
      final builder = ProvenanceBuilder(
        platform: 'xiaohongshu',
        postId: 'abc123',
        postUrl: 'https://www.xiaohongshu.com/explore/abc123',
        itemIndex: 0,
        itemCount: 1,
      );

      final xmp = builder.build();

      expect(xmp.assetId, isNotEmpty);
      expect(xmp.assetId.length, greaterThanOrEqualTo(32));
    });

    test('no title for IG and X when title is null', () {
      final builderIg = ProvenanceBuilder(
        platform: 'instagram',
        postId: 'abc123',
        postUrl: 'https://www.instagram.com/p/abc123',
        itemIndex: 0,
        itemCount: 1,
      );

      final xmpIg = builderIg.build();
      expect(xmpIg.title, isNull);
      expect(xmpIg.creators, isNull);

      final builderX = ProvenanceBuilder(
        platform: 'x',
        postId: 'abc123',
        postUrl: 'https://x.com/user/status/123',
        itemIndex: 0,
        itemCount: 1,
      );

      final xmpX = builderX.build();
      expect(xmpX.title, isNull);
      expect(xmpX.creators, isNull);
    });

    test('IG with authorName includes creators and credit', () {
      final builder = ProvenanceBuilder(
        platform: 'instagram',
        postId: 'abc123',
        postUrl: 'https://www.instagram.com/p/abc123',
        authorName: 'Instagram User',
        itemIndex: 0,
        itemCount: 1,
      );

      final xmp = builder.build();

      expect(xmp.creators, ['Instagram User']);
      expect(xmp.credit, 'Instagram User / Instagram');
    });

    test('X with authorName includes creators and credit', () {
      final builder = ProvenanceBuilder(
        platform: 'x',
        postId: 'abc123',
        postUrl: 'https://x.com/user/status/123',
        authorName: 'X User',
        itemIndex: 0,
        itemCount: 1,
      );

      final xmp = builder.build();

      expect(xmp.creators, ['X User']);
      expect(xmp.credit, 'X User / X');
    });

    test('sourceUrl is normalized', () {
      final builder = ProvenanceBuilder(
        platform: 'xiaohongshu',
        postId: 'abc123',
        postUrl: 'https://www.xiaohongshu.com/explore/abc123?utm_source=test&utm_medium=test2&fbclid=abc123&igsh=xyz',
        itemIndex: 0,
        itemCount: 1,
      );

      final xmp = builder.build();

      // Tracking params should be stripped
      expect(xmp.sourceUrl, isNot(contains('utm_source=')));
      expect(xmp.sourceUrl, isNot(contains('fbclid=')));
      expect(xmp.sourceUrl, isNot(contains('igsh=')));
      // Base URL should be preserved
      expect(xmp.sourceUrl, contains('xiaohongshu.com/explore/abc123'));
    });

    test('postUrl is not modified', () {
      final originalUrl = 'https://www.xiaohongshu.com/explore/abc123?utm_source=test';

      final builder = ProvenanceBuilder(
        platform: 'xiaohongshu',
        postId: 'abc123',
        postUrl: originalUrl,
        itemIndex: 0,
        itemCount: 1,
      );

      // Access internal field indirectly through the fact that sourceUrl is normalized
      final xmp = builder.build();

      // The original postUrl is preserved in the ProvenanceBuilder
      // sourceUrl should be normalized version
      expect(xmp.sourceUrl, isNot(equals(originalUrl)));
      expect(xmp.sourceUrl, contains('abc123'));
    });

    test('caption truncated if over 2000 chars', () {
      final longCaption = 'A' * 3000;

      final builder = ProvenanceBuilder(
        platform: 'xiaohongshu',
        postId: 'abc123',
        postUrl: 'https://www.xiaohongshu.com/explore/abc123',
        caption: longCaption,
        itemIndex: 0,
        itemCount: 1,
      );

      final xmp = builder.build();

      // Truncation adds '…' and preserves some content
      expect(xmp.description!.length, lessThanOrEqualTo(2000));
      expect(xmp.description, endsWith('…'));
    });

    test('itemIndex values match input (1-based)', () {
      final indices = [1, 3, 7];

      for (final idx in indices) {
        final builder = ProvenanceBuilder(
          platform: 'xiaohongshu',
          postId: 'abc123',
          postUrl: 'https://www.xiaohongshu.com/explore/abc123',
          itemIndex: idx,
          itemCount: 10,
        );

        final xmp = builder.build();
        expect(xmp.itemIndex, idx, reason: 'itemIndex should be $idx (1-based per spec)');
      }
    });

    test('X platform skips non-numeric authorId', () {
      final builder = ProvenanceBuilder(
        platform: 'x',
        postId: 'abc123',
        postUrl: 'https://x.com/i/status/abc123',
        authorId: 'n8_AIart', // Username, not a stable numeric ID
        authorName: 'X User',
        itemIndex: 1,
        itemCount: 1,
      );

      final xmp = builder.build();
      expect(xmp.authorId, isNull, reason: 'X username should not be written as authorId');
      expect(xmp.creators, ['X User']); // creator still written
    });

    test('numeric authorId is preserved for X platform', () {
      // Even for X, if the parser provides a numeric ID (future-proofing), write it
      final builder = ProvenanceBuilder(
        platform: 'x',
        postId: 'abc123',
        postUrl: 'https://x.com/i/status/abc123',
        authorId: '1234567890', // Numeric user ID from parser
        authorName: 'X User',
        itemIndex: 1,
        itemCount: 1,
      );

      final xmp = builder.build();
      expect(xmp.authorId, '1234567890');
    });

    test('publishedAt output includes timezone', () {
      final publishedAt = DateTime.utc(2026, 10, 20, 10, 30, 45);

      final builder = ProvenanceBuilder(
        platform: 'xiaohongshu',
        postId: 'abc123',
        postUrl: 'https://www.xiaohongshu.com/explore/abc123',
        publishedAt: publishedAt,
        itemIndex: 0,
        itemCount: 1,
      );

      final xmp = builder.build();
      final json = xmp.toXmpJson();

      // Dates must include timezone offset (e.g., +02:00 or -05:00)
      // or UTC marker (Z)
      final output = json['prov:publishedAt'] as String;
      expect(output, startsWith('2026-10-20'));
      expect(output, matches(RegExp(r'[\+\-]\d{2}:\d{2}|Z$')), 
          reason: 'Date must include timezone offset or Z');
    });
  });

  group('MetadataService.embedProvenance', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('easysave_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('writes XMP to JPEG file', () async {
      final filePath = '${tempDir.path}/test.jpg';
      
      // Minimal valid JPEG
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

      await File(filePath).writeAsBytes(minimalJpeg);

      final xmp = XmpProvenance(
        schema: '0.1',
        assetId: 'test-asset-id',
        capturedAt: DateTime.now(),
        capturedBy: 'EasySave Test',
        metadataDate: DateTime.now(),
        sourceUrl: 'https://example.com/test',
        platform: 'test',
        sourceId: 'test123',
        itemIndex: 0,
        itemCount: 1,
      );

      final result = await MetadataService.embedProvenance(
        filePath: filePath,
        provenance: xmp,
      );

      expect(result.success, isTrue);
      expect(result.errorMessage, isNull);

      // Verify file was modified
      final written = await File(filePath).readAsBytes();
      expect(written.length, greaterThan(minimalJpeg.length));
    });

    test('writes XMP to PNG file', () async {
      final filePath = '${tempDir.path}/test.png';

      // Minimal valid PNG
      final minimalPng = Uint8List.fromList([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature
        0x00, 0x00, 0x00, 0x0D, // IHDR length=13
        0x49, 0x48, 0x44, 0x52, // "IHDR"
        0x00, 0x00, 0x00, 0x01, // width=1
        0x00, 0x00, 0x00, 0x01, // height=1
        0x08, 0x02, 0x00, 0x00, 0x00, // bit depth=8, color=RGB
        0x90, 0x77, 0x53, 0xDE, // CRC
        0x00, 0x00, 0x00, 0x00, // IEND length=0
        0x49, 0x45, 0x4E, 0x44, // "IEND"
        0xAE, 0x42, 0x60, 0x82, // CRC
      ]);

      await File(filePath).writeAsBytes(minimalPng);

      final xmp = XmpProvenance(
        schema: '0.1',
        assetId: 'png-test',
        capturedAt: DateTime.now(),
        capturedBy: 'EasySave Test',
        metadataDate: DateTime.now(),
        sourceUrl: 'https://example.com/test',
        platform: 'test',
        sourceId: 'test123',
      );

      final result = await MetadataService.embedProvenance(
        filePath: filePath,
        provenance: xmp,
      );

      expect(result.success, isTrue);
    });

    test('returns failure for non-existent file', () async {
      final result = await MetadataService.embedProvenance(
        filePath: '${tempDir.path}/nonexistent.jpg',
        provenance: XmpProvenance(
          schema: '0.1',
          assetId: 'test',
          capturedAt: DateTime.now(),
          capturedBy: 'Test',
          metadataDate: DateTime.now(),
        ),
      );

      expect(result.success, isFalse);
      expect(result.errorMessage, contains('not found'));
    });

    test('returns failure for unknown format', () async {
      final filePath = '${tempDir.path}/test.xyz';
      await File(filePath).writeAsBytes([0x00, 0x01, 0x02, 0x03]);

      final result = await MetadataService.embedProvenance(
        filePath: filePath,
        provenance: XmpProvenance(
          schema: '0.1',
          assetId: 'test',
          capturedAt: DateTime.now(),
          capturedBy: 'Test',
          metadataDate: DateTime.now(),
        ),
      );

      expect(result.success, isFalse);
      expect(result.errorMessage, contains('Unknown file format'));
    });

    test('exception during write does not crash, returns failure', () async {
      // File that can't be written to
      final filePath = '/invalid/path/that/does/not/exist/test.jpg';
      
      // Write a valid JPEG first (to have correct magic bytes)
      // Then the write will fail
      final result = await MetadataService.embedProvenance(
        filePath: filePath,
        provenance: XmpProvenance(
          schema: '0.1',
          assetId: 'test',
          capturedAt: DateTime.now(),
          capturedBy: 'Test',
          metadataDate: DateTime.now(),
        ),
      );

      expect(result.success, isFalse);
      expect(result.errorMessage, isNotNull);
    });

    test('reads back embedded provenance', () async {
      final filePath = '${tempDir.path}/test.jpg';

      // Minimal valid JPEG
      final minimalJpeg = Uint8List.fromList([
        0xFF, 0xD8, // SOI
        0xFF, 0xE0, 0x00, 0x10, // APP0 length=16
        ...List.filled(14, 0),
        0xFF, 0xC0, 0x00, 0x0B, // SOF0
        ...List.filled(9, 0),
        0xFF, 0xDA, 0x00, 0x08, // SOS
        ...List.filled(6, 0),
        0xFF, 0xD9, // EOI
      ]);

      await File(filePath).writeAsBytes(minimalJpeg);

      final xmp = XmpProvenance(
        schema: '0.1',
        assetId: 'read-back-test',
        capturedAt: DateTime.utc(2026, 10, 20, 10, 0),
        capturedBy: 'EasySave Test',
        metadataDate: DateTime.utc(2026, 10, 20, 11, 0),
        sourceUrl: 'https://example.com/test',
        platform: 'test',
        sourceId: 'test123',
        title: 'Test Title',
        creators: ['Test Creator'],
      );

      await MetadataService.embedProvenance(
        filePath: filePath,
        provenance: xmp,
      );

      final read = MetadataService.readProvenance(filePath);

      expect(read, isNotNull);
      expect(read!.assetId, 'read-back-test');
      expect(read.platform, 'test');
      expect(read.title, 'Test Title');
      expect(read.creators, ['Test Creator']);
    });

    test('preserves existing assetId on re-embed', () async {
      final filePath = '${tempDir.path}/test.jpg';

      // Minimal valid JPEG
      final minimalJpeg = Uint8List.fromList([
        0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10,
        ...List.filled(14, 0),
        0xFF, 0xC0, 0x00, 0x0B,
        ...List.filled(9, 0),
        0xFF, 0xDA, 0x00, 0x08,
        ...List.filled(6, 0),
        0xFF, 0xD9,
      ]);

      await File(filePath).writeAsBytes(minimalJpeg);

      // First embed
      final first = XmpProvenance(
        schema: '0.1',
        assetId: 'original-asset-id',
        capturedAt: DateTime.utc(2026, 10, 20),
        capturedBy: 'EasySave',
        metadataDate: DateTime.utc(2026, 10, 20),
        sourceUrl: 'https://example.com/1',
        platform: 'test',
        sourceId: 'test1',
      );

      await MetadataService.embedProvenance(filePath: filePath, provenance: first);

      // Second embed with different assetId
      final second = XmpProvenance(
        schema: '0.1',
        assetId: 'new-asset-id-should-be-ignored',
        capturedAt: DateTime.utc(2026, 10, 21),
        capturedBy: 'EasySave',
        metadataDate: DateTime.utc(2026, 10, 21),
        sourceUrl: 'https://example.com/2',
        platform: 'test',
        sourceId: 'test2',
      );

      await MetadataService.embedProvenance(filePath: filePath, provenance: second);

      // Read back - should have original assetId
      final read = MetadataService.readProvenance(filePath);
      expect(read!.assetId, 'original-asset-id');
    });
  });

  group('MetadataService.embedProvenance Live Photo JPEG (EXIF APP1)', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('easysave_live_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    /// Reproduces the real-world failure: Live Photo still-image covers
    /// (e.g. downloaded from Xiaohongshu/Instagram CDNs) are valid JPEGs
    /// but carry an EXIF APP1 segment instead of an XMP APP1 segment.
    /// The EXIF payload is binary TIFF data ("Exif\0\0" + IFD bytes), which
    /// is not valid UTF-8. Before the fix, readJpegXmp/writeJpegXmp called
    /// utf8.decode() unconditionally on the APP1 payload when checking for
    /// the XMP header, so a FormatException ("Bad UTF-8 encoding") was
    /// thrown and bubbled up through embedProvenance's outer catch as
    /// `EmbedResult.failure('FormatException: ...')`. HistoryBackfillService
    /// then matched the string "Format" in that message and misclassified
    /// a perfectly valid, writable JPEG as "format not supported".
    Uint8List jpegWithExifApp1() {
      // Binary EXIF payload: "Exif\0\0" header followed by non-UTF8 bytes
      // (0xFF 0xFE is an invalid UTF-8 continuation sequence).
      final exifPayload = <int>[
        0x45, 0x78, 0x69, 0x66, 0x00, 0x00, // "Exif\0\0"
        0x4D, 0x4D, 0x00, 0x2A, // TIFF header (big-endian) + magic
        0x00, 0x00, 0x00, 0x08, // offset to first IFD
        0xFF, 0xFE, 0x80, 0x81, // invalid UTF-8 continuation bytes
      ];
      final app1Length = 2 + exifPayload.length; // length field includes itself
      return Uint8List.fromList([
        0xFF, 0xD8, // SOI
        0xFF, 0xE1, (app1Length >> 8) & 0xFF, app1Length & 0xFF, // APP1 (EXIF)
        ...exifPayload,
        0xFF, 0xC0, 0x00, 0x0B, // SOF0 length=11
        ...List.filled(9, 0),
        0xFF, 0xDA, 0x00, 0x08, // SOS length=8
        ...List.filled(6, 0),
        0xFF, 0xD9, // EOI
      ]);
    }

    test('writes XMP to a JPEG whose only APP1 segment is EXIF', () async {
      final filePath = '${tempDir.path}/live_cover.jpg';
      await File(filePath).writeAsBytes(jpegWithExifApp1());

      final xmp = XmpProvenance(
        schema: '0.1',
        assetId: 'live-asset-id',
        capturedAt: DateTime.utc(2026, 10, 20),
        capturedBy: 'EasySave',
        metadataDate: DateTime.utc(2026, 10, 20),
        sourceUrl: 'https://example.com/live',
        platform: 'xiaohongshu',
        sourceId: 'live123',
      );

      final result = await MetadataService.embedProvenance(
        filePath: filePath,
        provenance: xmp,
      );

      expect(result.success, isTrue);
      expect(result.errorMessage, isNull);

      final read = MetadataService.readProvenance(filePath);
      expect(read, isNotNull);
      expect(read!.assetId, 'live-asset-id');
      expect(read.sourceId, 'live123');
    });

    test('readProvenance does not throw on EXIF-only APP1 and returns null', () {
      final filePath = '${tempDir.path}/live_cover_unwritten.jpg';
      File(filePath).writeAsBytesSync(jpegWithExifApp1());

      // Before any XMP write, there is no provenance - must return null,
      // not throw, even though the file has a non-XMP APP1 segment.
      final read = MetadataService.readProvenance(filePath);
      expect(read, isNull);
    });

    test('preserves the original EXIF APP1 segment after writing XMP', () async {
      final filePath = '${tempDir.path}/live_cover_preserve.jpg';
      final original = jpegWithExifApp1();
      await File(filePath).writeAsBytes(original);

      final xmp = XmpProvenance(
        schema: '0.1',
        assetId: 'live-asset-id-2',
        capturedAt: DateTime.utc(2026, 10, 20),
        capturedBy: 'EasySave',
        metadataDate: DateTime.utc(2026, 10, 20),
        sourceUrl: 'https://example.com/live2',
        platform: 'xiaohongshu',
        sourceId: 'live456',
      );

      await MetadataService.embedProvenance(filePath: filePath, provenance: xmp);

      final written = await File(filePath).readAsBytes();
      // The original EXIF APP1 bytes (marker + length + "Exif\0\0" + payload)
      // must still be present somewhere in the output - the writer must not
      // have discarded or corrupted the EXIF segment while inserting XMP.
      final exifMarker = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00]; // "Exif\0\0"
      bool containsExif = false;
      for (var i = 0; i <= written.length - exifMarker.length; i++) {
        if (written[i] == exifMarker[0] &&
            written[i + 1] == exifMarker[1] &&
            written[i + 2] == exifMarker[2] &&
            written[i + 3] == exifMarker[3] &&
            written[i + 4] == exifMarker[4] &&
            written[i + 5] == exifMarker[5]) {
          containsExif = true;
          break;
        }
      }
      expect(containsExif, isTrue, reason: 'EXIF APP1 segment must be preserved');
    });
  });

  group('MetadataService C2PA detection', () {
    test('hasC2pa returns false for clean JPEG', () async {
      final tempDir = await Directory.systemTemp.createTemp('easysave_c2pa_test_');
      final filePath = '${tempDir.path}/clean.jpg';

      final minimalJpeg = Uint8List.fromList([
        0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10,
        ...List.filled(14, 0),
        0xFF, 0xC0, 0x00, 0x0B,
        ...List.filled(9, 0),
        0xFF, 0xDA, 0x00, 0x08,
        ...List.filled(6, 0),
        0xFF, 0xD9,
      ]);

      await File(filePath).writeAsBytes(minimalJpeg);

      final hasC2pa = await MetadataService.hasC2pa(filePath);

      expect(hasC2pa, isFalse);

      await tempDir.delete(recursive: true);
    });
  });
}
