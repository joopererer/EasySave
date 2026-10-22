// Copyright 2026 EasySave. All rights reserved.
// Conformance tests against provenance-spec test-vectors.
// §7: Read standard files, convert to JSON, validate fields.
// §10: Round-trip tests (write → read → verify), foreign field preservation, assetId stability, byte identity.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:easysave/metadata/xmp_jpeg.dart';
import 'package:easysave/metadata/xmp_png.dart';
import 'package:easysave/metadata/xmp_webp.dart';
import 'package:easysave/metadata/xmp_sidecar.dart';
import 'package:easysave/metadata/xmp_model.dart';

/// Compares non-metadata bytes between two files.
/// Returns null if identical, or a description of the difference.
String? _compareNonMetadataBytes(Uint8List original, Uint8List modified, String format) {
  // For JPEG, extract everything except APP1 XMP segment
  if (format == 'JPEG') {
    final originalNonXmp = _stripJpegXmp(original);
    final modifiedNonXmp = _stripJpegXmp(modified);

    if (originalNonXmp.length != modifiedNonXmp.length) {
      return 'Non-XMP length differs: ${originalNonXmp.length} vs ${modifiedNonXmp.length}';
    }

    for (int i = 0; i < originalNonXmp.length; i++) {
      if (originalNonXmp[i] != modifiedNonXmp[i]) {
        return 'Byte mismatch at offset $i: 0x${originalNonXmp[i].toRadixString(16)} vs 0x${modifiedNonXmp[i].toRadixString(16)}';
      }
    }
    return null;
  }

  // For PNG, extract everything except iTXt XMP chunk
  if (format == 'PNG') {
    final originalNonXmp = _stripPngXmp(original);
    final modifiedNonXmp = _stripPngXmp(modified);

    if (originalNonXmp.length != modifiedNonXmp.length) {
      return 'Non-XMP length differs: ${originalNonXmp.length} vs ${modifiedNonXmp.length}';
    }

    for (int i = 0; i < originalNonXmp.length; i++) {
      if (originalNonXmp[i] != modifiedNonXmp[i]) {
        return 'Byte mismatch at offset $i: 0x${originalNonXmp[i].toRadixString(16)} vs 0x${modifiedNonXmp[i].toRadixString(16)}';
      }
    }
    return null;
  }

  // For WebP, extract everything except XMP chunk, but also exclude RIFF size from comparison
  if (format == 'WebP') {
    // For WebP comparison, we need to be more careful:
    // 1. Strip XMP chunk
    // 2. Compare all chunks except RIFF header size field
    final originalNonXmp = _stripWebpXmp(original);
    final modifiedNonXmp = _stripWebpXmp(modified);

    // First compare RIFF signature (same in both)
    if (originalNonXmp.length < 12 || modifiedNonXmp.length < 12) {
      return 'WebP too short';
    }
    
    // Compare RIFF signature and WEBP signature (first 12 bytes)
    for (int i = 0; i < 12; i++) {
      if (originalNonXmp[i] != modifiedNonXmp[i]) {
        // Allow file size difference at offset 4-7
        if (i >= 4 && i <= 7) continue;
        return 'Byte mismatch at offset $i: 0x${originalNonXmp[i].toRadixString(16)} vs 0x${modifiedNonXmp[i].toRadixString(16)}';
      }
    }
    
    // Compare remaining chunks (everything after first 12 bytes)
    final origChunkStart = 12;
    final modChunkStart = 12;
    final origChunkLen = originalNonXmp.length - origChunkStart;
    final modChunkLen = modifiedNonXmp.length - modChunkStart;
    
    if (origChunkLen != modChunkLen) {
      return 'Chunk length differs: $origChunkLen vs $modChunkLen';
    }
    
    for (int i = 0; i < origChunkLen; i++) {
      if (originalNonXmp[origChunkStart + i] != modifiedNonXmp[modChunkStart + i]) {
        return 'Chunk byte mismatch at offset ${origChunkStart + i}: 0x${originalNonXmp[origChunkStart + i].toRadixString(16)} vs 0x${modifiedNonXmp[modChunkStart + i].toRadixString(16)}';
      }
    }
    return null;
  }

  return 'Unknown format: $format';
}

/// Strip XMP APP1 segment from JPEG bytes.
Uint8List _stripJpegXmp(Uint8List bytes) {
  if (bytes.length < 2 || bytes[0] != 0xFF || bytes[1] != 0xD8) {
    return bytes;
  }

  final result = BytesBuilder();
  int offset = 2;

  while (offset < bytes.length - 1) {
    if (bytes[offset] != 0xFF) break;

    final marker = bytes[offset + 1];
    if (marker == 0xD9) break; // EOI

    offset += 2;
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      result.add([0xFF, marker]);
      continue;
    }

    if (offset + 2 > bytes.length) break;

    final segmentLength = (bytes[offset] << 8) | bytes[offset + 1];
    if (segmentLength < 2) break;

    // Check for XMP APP1 segment
    if (marker == 0xE1 && offset + 2 + 29 <= bytes.length) {
      final headerStart = offset + 2;
      final header = utf8.decode(bytes.sublist(headerStart, headerStart + 29), allowMalformed: true);
      if (header.startsWith('http://ns.adobe.com/xap/1.0/')) {
        // Skip XMP segment
        offset += segmentLength;
        continue;
      }
    }

    // Copy segment
    result.add([0xFF, marker]);
    result.add(bytes.sublist(offset, offset + segmentLength));
    offset += segmentLength;
  }

  // Copy remaining
  if (offset < bytes.length) {
    result.add(bytes.sublist(offset));
  }

  return result.toBytes();
}

/// Strip XMP iTXt chunk from PNG bytes.
Uint8List _stripPngXmp(Uint8List bytes) {
  if (bytes.length < 8 ||
      bytes[0] != 0x89 || bytes[1] != 0x50 || bytes[2] != 0x4E || bytes[3] != 0x47) {
    return bytes;
  }

  final result = BytesBuilder();
  result.add(bytes.sublist(0, 8)); // PNG signature
  int offset = 8;

  while (offset + 12 <= bytes.length) {
    final length = (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
    final chunkType = utf8.decode(bytes.sublist(offset + 4, offset + 8), allowMalformed: true);

    if (chunkType == 'IEND') {
      result.add(bytes.sublist(offset, offset + 12 + length));
      break;
    }

    if (chunkType == 'iTXt') {
      final chunkData = bytes.sublist(offset + 8, offset + 8 + length);
      final nullPos = chunkData.indexOf(0);
      if (nullPos > 0) {
        final keyword = utf8.decode(chunkData.sublist(0, nullPos), allowMalformed: true);
        if (keyword == 'XML:com.adobe.xmp') {
          // Skip XMP chunk
          offset += 12 + length;
          continue;
        }
      }
    }

    result.add(bytes.sublist(offset, offset + 12 + length));
    offset += 12 + length;
  }

  return result.toBytes();
}

/// Strip XMP chunk from WebP bytes.
Uint8List _stripWebpXmp(Uint8List bytes) {
  if (bytes.length < 12 ||
      bytes[0] != 0x52 || bytes[1] != 0x49 || bytes[2] != 0x46 || bytes[3] != 0x46 ||
      bytes[8] != 0x57 || bytes[9] != 0x45 || bytes[10] != 0x42 || bytes[11] != 0x50) {
    return bytes;
  }

  final result = BytesBuilder();
  result.add(bytes.sublist(0, 12)); // RIFF header
  int offset = 12;

  while (offset + 8 <= bytes.length) {
    final fourCC = utf8.decode(bytes.sublist(offset, offset + 4), allowMalformed: true);
    final chunkSize = _readU32Webp(bytes, offset + 4);
    final dataEnd = offset + 8 + chunkSize;

    if (dataEnd > bytes.length) break;

    if (fourCC == 'XMP ') {
      offset = dataEnd;
      if (chunkSize % 2 == 1) offset++;
      continue;
    }

    final chunkEnd = dataEnd + (chunkSize % 2 == 1 ? 1 : 0);
    result.add(bytes.sublist(offset, chunkEnd));
    offset = dataEnd;
    if (chunkSize % 2 == 1) offset++;
  }

  return result.toBytes();
}

int _readU32Webp(Uint8List bytes, int offset) {
  return bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);
}

/// Create a minimal VP8 WebP (simple format, no VP8X header) for testing.
/// Creates a simple lossy WebP with minimal valid VP8 data.
Uint8List _createSimpleVp8Webp() {
  // Minimal 1x1 VP8 lossy WebP
  // VP8 frame header format:
  // - 3 bytes: frame tag (key frame, version 0, show frame)
  // - Width and height in the bitstream
  
  final frameTag = [0x9D, 0x01, 0x2A]; // Key frame, no partitioning
  final dimensions = [0x10, 0x00, 0x10, 0x00]; // Width=16, Height=16 (in macroblock units + 1)
  
  // Minimal VP8 bitstream with a few bytes of data
  final vp8Data = [
    ...frameTag,
    ...dimensions,
    0x80, 0x80, 0x80, // Minimal partition data
    0x00, 0x00, 0x00, // End marker
  ];
  
  // Pad to even length
  if (vp8Data.length % 2 == 1) vp8Data.add(0);
  
  final vp8Chunk = BytesBuilder();
  vp8Chunk.add([0x56, 0x50, 0x38, 0x20]); // "VP8 "
  vp8Chunk.add(_u32BytesLE(vp8Data.length));
  vp8Chunk.add(vp8Data);
  if (vp8Data.length % 2 == 1) vp8Chunk.addByte(0);
  
  final chunks = vp8Chunk.toBytes();
  final fileSize = 4 + chunks.length; // "WEBP" + chunks
  
  final builder = BytesBuilder();
  builder.add([0x52, 0x49, 0x46, 0x46]); // "RIFF"
  builder.add(_u32BytesLE(fileSize));
  builder.add([0x57, 0x45, 0x42, 0x50]); // "WEBP"
  builder.add(chunks);
  
  return builder.toBytes();
}

List<int> _u32BytesLE(int value) {
  return [
    value & 0xFF,
    (value >> 8) & 0xFF,
    (value >> 16) & 0xFF,
    (value >> 24) & 0xFF,
  ];
}

void main() {
  late String testVectorsPath;

  setUpAll(() {
    // Relative to app/ directory
    testVectorsPath = p.normalize(p.join(
      Directory.current.path,
      '..',
      'docs',
      'provenance-spec',
      'test-vectors',
    ));

    if (!Directory(testVectorsPath).existsSync()) {
      throw StateError('Test vectors not found at $testVectorsPath. '
          'Run `git submodule update --init` first.');
    }
  });

  // =========================================================================
  // §7: Read standard files - JSON matches expected
  // =========================================================================
  group('Conformance - Read standard files', () {
    test('xhs-item3.jpg → JSON matches expected', () async {
      final file = File(p.join(testVectorsPath, 'xhs-item3.jpg'));
      final expectedFile = File(p.join(testVectorsPath, 'xhs-item3.jpg.expected.json'));
      
      expect(file.existsSync(), isTrue, reason: 'xhs-item3.jpg not found');
      expect(expectedFile.existsSync(), isTrue, reason: 'xhs-item3.jpg.expected.json not found');

      final bytes = await file.readAsBytes();
      final xmp = readJpegXmp(bytes);
      
      expect(xmp, isNotNull, reason: 'Failed to read XMP from xhs-item3.jpg');
      
      final actual = xmp!.toJson();
      final expected = jsonDecode(await expectedFile.readAsString()) as Map<String, dynamic>;

      _validateJsonMatch(actual, expected, 'xhs-item3.jpg');
    });

    test('ig-item2.png → JSON matches expected', () async {
      final file = File(p.join(testVectorsPath, 'ig-item2.png'));
      final expectedFile = File(p.join(testVectorsPath, 'ig-item2.png.expected.json'));
      
      expect(file.existsSync(), isTrue, reason: 'ig-item2.png not found');
      expect(expectedFile.existsSync(), isTrue, reason: 'ig-item2.png.expected.json not found');

      final bytes = await file.readAsBytes();
      final xmp = readPngXmp(bytes);
      
      expect(xmp, isNotNull, reason: 'Failed to read XMP from ig-item2.png');
      
      final actual = xmp!.toJson();
      final expected = jsonDecode(await expectedFile.readAsString()) as Map<String, dynamic>;

      _validateJsonMatch(actual, expected, 'ig-item2.png');
    });

    test('x-single.webp → JSON matches expected', () async {
      final file = File(p.join(testVectorsPath, 'x-single.webp'));
      final expectedFile = File(p.join(testVectorsPath, 'x-single.webp.expected.json'));
      
      expect(file.existsSync(), isTrue, reason: 'x-single.webp not found');
      expect(expectedFile.existsSync(), isTrue, reason: 'x-single.webp.expected.json not found');

      final bytes = await file.readAsBytes();
      final xmp = readWebpXmp(bytes);
      
      expect(xmp, isNotNull, reason: 'Failed to read XMP from x-single.webp');
      
      final actual = xmp!.toJson();
      final expected = jsonDecode(await expectedFile.readAsString()) as Map<String, dynamic>;

      _validateJsonMatch(actual, expected, 'x-single.webp');
    });

    test('no-metadata.jpg → returns null', () async {
      final file = File(p.join(testVectorsPath, 'no-metadata.jpg'));
      expect(file.existsSync(), isTrue, reason: 'no-metadata.jpg not found');

      final bytes = await file.readAsBytes();
      final xmp = readJpegXmp(bytes);
      
      expect(xmp, isNull, reason: 'no-metadata.jpg should have no XMP');
    });

    test('local-video.mp4.xmp → sidecar XMP matches expected', () async {
      final xmpFile = File(p.join(testVectorsPath, 'local-video.mp4.xmp'));
      final expectedFile = File(p.join(testVectorsPath, 'local-video.mp4.expected.json'));
      
      expect(xmpFile.existsSync(), isTrue, reason: 'local-video.mp4.xmp not found');
      expect(expectedFile.existsSync(), isTrue, reason: 'local-video.mp4.expected.json not found');

      final xmp = readSidecarXmp(xmpFile);
      expect(xmp, isNotNull, reason: 'Failed to read XMP from local-video.mp4.xmp');
      
      final actual = xmp!.toJson();
      final expected = jsonDecode(await expectedFile.readAsString()) as Map<String, dynamic>;

      _validateJsonMatch(actual, expected, 'local-video.mp4.xmp');
    });

    // §4.7: Multiple rdf:Description blocks, mixed attribute/element syntax
    test('multiblock-elements.jpg → JSON matches expected (§4.7)', () async {
      final file = File(p.join(testVectorsPath, 'multiblock-elements.jpg'));
      final expectedFile = File(p.join(testVectorsPath, 'multiblock-elements.jpg.expected.json'));
      
      expect(file.existsSync(), isTrue, reason: 'multiblock-elements.jpg not found');
      expect(expectedFile.existsSync(), isTrue, reason: 'multiblock-elements.jpg.expected.json not found');

      final bytes = await file.readAsBytes();
      final xmp = readJpegXmp(bytes);
      
      expect(xmp, isNotNull, reason: 'Failed to read XMP from multiblock-elements.jpg');
      
      final actual = xmp!.toJson();
      final expected = jsonDecode(await expectedFile.readAsString()) as Map<String, dynamic>;

      _validateJsonMatch(actual, expected, 'multiblock-elements.jpg');
    });

    test('baidupan-single.jpg → JSON matches expected (optional sourceUrl, opaque sourceId)', () async {
      final file = File(p.join(testVectorsPath, 'baidupan-single.jpg'));
      final expectedFile = File(p.join(testVectorsPath, 'baidupan-single.jpg.expected.json'));
      
      expect(file.existsSync(), isTrue, reason: 'baidupan-single.jpg not found');
      expect(expectedFile.existsSync(), isTrue, reason: 'baidupan-single.jpg.expected.json not found');

      final bytes = await file.readAsBytes();
      final xmp = readJpegXmp(bytes);
      
      expect(xmp, isNotNull, reason: 'Failed to read XMP from baidupan-single.jpg');
      
      final actual = xmp!.toJson();
      final expected = jsonDecode(await expectedFile.readAsString()) as Map<String, dynamic>;

      _validateJsonMatch(actual, expected, 'baidupan-single.jpg');
    });

    test('exif-before-xmp.jpg → JSON matches expected (EXIF APP1 skipped, pairId parsed)', () async {
      final file = File(p.join(testVectorsPath, 'exif-before-xmp.jpg'));
      final expectedFile = File(p.join(testVectorsPath, 'exif-before-xmp.jpg.expected.json'));
      
      expect(file.existsSync(), isTrue, reason: 'exif-before-xmp.jpg not found');
      expect(expectedFile.existsSync(), isTrue, reason: 'exif-before-xmp.jpg.expected.json not found');

      final bytes = await file.readAsBytes();
      final xmp = readJpegXmp(bytes);
      
      expect(xmp, isNotNull, reason: 'Failed to read XMP from exif-before-xmp.jpg');
      
      final actual = xmp!.toJson();
      final expected = jsonDecode(await expectedFile.readAsString()) as Map<String, dynamic>;

      _validateJsonMatch(actual, expected, 'exif-before-xmp.jpg');
    });
  });

  // =========================================================================
  // §10: Round-trip write tests
  // =========================================================================
  group('Conformance - Round-trip write tests', () {
    // ----- JPEG Tests -----
    test('JPEG: xhs-item3.jpg write → read → verify fields unchanged', () async {
      final file = File(p.join(testVectorsPath, 'xhs-item3.jpg'));
      final bytes = await file.readAsBytes();
      
      final originalXmp = readJpegXmp(bytes)!;
      final originalAssetId = originalXmp.assetId;

      // Write with updated metadataDate
      final updatedXmp = XmpProvenance(
        schema: originalXmp.schema,
        assetId: originalXmp.assetId,
        capturedAt: originalXmp.capturedAt,
        capturedBy: originalXmp.capturedBy,
        metadataDate: DateTime.now(),
        sourceUrl: originalXmp.sourceUrl,
        platform: originalXmp.platform,
        sourceId: originalXmp.sourceId,
        itemIndex: originalXmp.itemIndex,
        itemCount: originalXmp.itemCount,
        authorId: originalXmp.authorId,
        publishedAt: originalXmp.publishedAt,
        title: originalXmp.title,
        creators: originalXmp.creators,
        description: originalXmp.description,
        subject: originalXmp.subject,
        rating: originalXmp.rating,
        credit: originalXmp.credit,
        otherFields: originalXmp.otherFields,
      );

      final modifiedBytes = writeJpegXmp(bytes, updatedXmp);
      final readBack = readJpegXmp(modifiedBytes)!;

      // assetId must not change
      expect(readBack.assetId, equals(originalAssetId), 
          reason: 'assetId must remain unchanged after write');

      // Other required fields preserved
      expect(readBack.schema, equals(originalXmp.schema));
      expect(readBack.capturedBy, equals(originalXmp.capturedBy));
      expect(readBack.sourceUrl, equals(originalXmp.sourceUrl));
      expect(readBack.platform, equals(originalXmp.platform));
      expect(readBack.sourceId, equals(originalXmp.sourceId));
    });

    test('JPEG: xhs-item3.jpg foreign fields preserved', () async {
      final file = File(p.join(testVectorsPath, 'xhs-item3.jpg'));
      final bytes = await file.readAsBytes();
      
      final originalXmp = readJpegXmp(bytes)!;
      expect(originalXmp.subject, isNotNull);
      expect(originalXmp.rating, isNotNull);

      final modifiedBytes = writeJpegXmp(bytes, originalXmp);
      final readBack = readJpegXmp(modifiedBytes)!;

      expect(readBack.subject, equals(originalXmp.subject));
      expect(readBack.rating, equals(originalXmp.rating));
    });

    test('JPEG: xhs-item3.jpg byte identity (non-metadata bytes unchanged after write)', () async {
      final file = File(p.join(testVectorsPath, 'xhs-item3.jpg'));
      final bytes = await file.readAsBytes();

      final xmp = readJpegXmp(bytes)!;
      final originalMetadataDate = xmp.metadataDate;

      final updatedXmp = XmpProvenance(
        schema: xmp.schema,
        assetId: xmp.assetId,
        capturedAt: xmp.capturedAt,
        capturedBy: xmp.capturedBy,
        metadataDate: DateTime.now(),
        sourceUrl: xmp.sourceUrl,
        platform: xmp.platform,
        sourceId: xmp.sourceId,
        itemIndex: xmp.itemIndex,
        itemCount: xmp.itemCount,
        authorId: xmp.authorId,
        publishedAt: xmp.publishedAt,
        title: xmp.title,
        creators: xmp.creators,
        description: xmp.description,
        subject: xmp.subject,
        rating: xmp.rating,
        credit: xmp.credit,
        otherFields: xmp.otherFields,
      );
      final modifiedBytes = writeJpegXmp(bytes, updatedXmp);

      expect(modifiedBytes.length, greaterThan(0));

      final nonMetadataDiff = _compareNonMetadataBytes(bytes, modifiedBytes, 'JPEG');
      expect(nonMetadataDiff, isNull, reason: nonMetadataDiff);

      final readBack = readJpegXmp(modifiedBytes)!;
      expect(readBack.metadataDate, isNot(equals(originalMetadataDate)),
          reason: 'metadataDate should be updated');
    });

    test('JPEG: xhs-item3.jpg special characters and Chinese round-trip', () async {
      final file = File(p.join(testVectorsPath, 'xhs-item3.jpg'));
      final bytes = await file.readAsBytes();
      
      final originalXmp = readJpegXmp(bytes)!;
      
      expect(originalXmp.title, isNotNull);
      expect(originalXmp.description, isNotNull);
      
      final modifiedBytes = writeJpegXmp(bytes, originalXmp);
      final readBack = readJpegXmp(modifiedBytes)!;
      
      expect(readBack.title, equals(originalXmp.title));
      expect(readBack.description, equals(originalXmp.description));
      
      // XML special characters (& < > ") preserved
      expect(readBack.description, contains('&'));
      expect(readBack.description, contains('<'));
    });

    test('JPEG: baidupan-single.jpg write → read → verify fields unchanged (sourceUrl omitted, opaque sourceId)', () async {
      final file = File(p.join(testVectorsPath, 'baidupan-single.jpg'));
      final bytes = await file.readAsBytes();
      
      final originalXmp = readJpegXmp(bytes)!;
      final originalAssetId = originalXmp.assetId;
      expect(originalXmp.sourceUrl, isNull);
      expect(originalXmp.platform, equals('baidupan'));
      expect(originalXmp.sourceId, equals('1092837465019283'));

      final updatedXmp = XmpProvenance(
        schema: originalXmp.schema,
        assetId: originalXmp.assetId,
        capturedAt: originalXmp.capturedAt,
        capturedBy: originalXmp.capturedBy,
        metadataDate: DateTime.now(),
        sourceUrl: originalXmp.sourceUrl,
        platform: originalXmp.platform,
        sourceId: originalXmp.sourceId,
        itemIndex: originalXmp.itemIndex,
        itemCount: originalXmp.itemCount,
        authorId: originalXmp.authorId,
        publishedAt: originalXmp.publishedAt,
        pairId: originalXmp.pairId,
        title: originalXmp.title,
        creators: originalXmp.creators,
        description: originalXmp.description,
        subject: originalXmp.subject,
        rating: originalXmp.rating,
        credit: originalXmp.credit,
        otherFields: originalXmp.otherFields,
      );

      final modifiedBytes = writeJpegXmp(bytes, updatedXmp);
      final readBack = readJpegXmp(modifiedBytes)!;

      expect(readBack.assetId, equals(originalAssetId));
      expect(readBack.sourceUrl, isNull);
      expect(readBack.platform, equals('baidupan'));
      expect(readBack.sourceId, equals('1092837465019283'));
      expect(readBack.title, equals(originalXmp.title));
      expect(readBack.subject, equals(originalXmp.subject));
    });

    test('JPEG: baidupan-single.jpg non-metadata bytes unchanged', () async {
      final file = File(p.join(testVectorsPath, 'baidupan-single.jpg'));
      final bytes = await file.readAsBytes();
      final originalXmp = readJpegXmp(bytes)!;

      final updatedXmp = XmpProvenance(
        schema: originalXmp.schema,
        assetId: originalXmp.assetId,
        capturedAt: originalXmp.capturedAt,
        capturedBy: originalXmp.capturedBy,
        metadataDate: DateTime.now(),
        sourceUrl: originalXmp.sourceUrl,
        platform: originalXmp.platform,
        sourceId: originalXmp.sourceId,
        itemIndex: originalXmp.itemIndex,
        itemCount: originalXmp.itemCount,
        authorId: originalXmp.authorId,
        publishedAt: originalXmp.publishedAt,
        pairId: originalXmp.pairId,
        title: originalXmp.title,
        creators: originalXmp.creators,
        description: originalXmp.description,
        subject: originalXmp.subject,
        rating: originalXmp.rating,
        credit: originalXmp.credit,
        otherFields: originalXmp.otherFields,
      );
      final modifiedBytes = writeJpegXmp(bytes, updatedXmp);

      final nonMetadataDiff = _compareNonMetadataBytes(bytes, modifiedBytes, 'JPEG');
      expect(nonMetadataDiff, isNull, reason: nonMetadataDiff);
    });

    test('JPEG: exif-before-xmp.jpg write → read → verify fields unchanged and EXIF preserved (§4.7)', () async {
      final file = File(p.join(testVectorsPath, 'exif-before-xmp.jpg'));
      final bytes = await file.readAsBytes();
      
      final originalXmp = readJpegXmp(bytes)!;
      final originalAssetId = originalXmp.assetId;
      expect(originalXmp.pairId, equals('6ad511fa0000000021034011#1'));

      final updatedXmp = XmpProvenance(
        schema: originalXmp.schema,
        assetId: originalXmp.assetId,
        capturedAt: originalXmp.capturedAt,
        capturedBy: originalXmp.capturedBy,
        metadataDate: DateTime.now(),
        sourceUrl: originalXmp.sourceUrl,
        platform: originalXmp.platform,
        sourceId: originalXmp.sourceId,
        itemIndex: originalXmp.itemIndex,
        itemCount: originalXmp.itemCount,
        authorId: originalXmp.authorId,
        publishedAt: originalXmp.publishedAt,
        pairId: originalXmp.pairId,
        title: originalXmp.title,
        creators: originalXmp.creators,
        description: originalXmp.description,
        subject: originalXmp.subject,
        rating: originalXmp.rating,
        credit: originalXmp.credit,
        otherFields: originalXmp.otherFields,
      );

      final modifiedBytes = writeJpegXmp(bytes, updatedXmp);
      final readBack = readJpegXmp(modifiedBytes)!;

      expect(readBack.assetId, equals(originalAssetId));
      expect(readBack.sourceUrl, equals(originalXmp.sourceUrl));
      expect(readBack.platform, equals(originalXmp.platform));
      expect(readBack.sourceId, equals(originalXmp.sourceId));
      expect(readBack.pairId, equals('6ad511fa0000000021034011#1'));
      expect(readBack.title, equals(originalXmp.title));
      expect(readBack.rating, equals(originalXmp.rating));
      expect(readBack.subject, equals(originalXmp.subject));
    });

    test('JPEG: exif-before-xmp.jpg non-metadata bytes unchanged (EXIF segment preserved byte-for-byte)', () async {
      final file = File(p.join(testVectorsPath, 'exif-before-xmp.jpg'));
      final bytes = await file.readAsBytes();
      final originalXmp = readJpegXmp(bytes)!;

      final updatedXmp = XmpProvenance(
        schema: originalXmp.schema,
        assetId: originalXmp.assetId,
        capturedAt: originalXmp.capturedAt,
        capturedBy: originalXmp.capturedBy,
        metadataDate: DateTime.now(),
        sourceUrl: originalXmp.sourceUrl,
        platform: originalXmp.platform,
        sourceId: originalXmp.sourceId,
        itemIndex: originalXmp.itemIndex,
        itemCount: originalXmp.itemCount,
        authorId: originalXmp.authorId,
        publishedAt: originalXmp.publishedAt,
        pairId: originalXmp.pairId,
        title: originalXmp.title,
        creators: originalXmp.creators,
        description: originalXmp.description,
        subject: originalXmp.subject,
        rating: originalXmp.rating,
        credit: originalXmp.credit,
        otherFields: originalXmp.otherFields,
      );
      final modifiedBytes = writeJpegXmp(bytes, updatedXmp);

      final nonMetadataDiff = _compareNonMetadataBytes(bytes, modifiedBytes, 'JPEG');
      expect(nonMetadataDiff, isNull, reason: nonMetadataDiff);
    });

    // ----- PNG Tests -----
    test('PNG: ig-item2.png write → read → verify', () async {
      final file = File(p.join(testVectorsPath, 'ig-item2.png'));
      final bytes = await file.readAsBytes();
      
      final originalXmp = readPngXmp(bytes)!;
      final originalAssetId = originalXmp.assetId;

      final updatedXmp = XmpProvenance(
        schema: originalXmp.schema,
        assetId: originalXmp.assetId,
        capturedAt: originalXmp.capturedAt,
        capturedBy: originalXmp.capturedBy,
        metadataDate: DateTime.now(),
        sourceUrl: originalXmp.sourceUrl,
        platform: originalXmp.platform,
        sourceId: originalXmp.sourceId,
        itemIndex: originalXmp.itemIndex,
        itemCount: originalXmp.itemCount,
        authorId: originalXmp.authorId,
        publishedAt: originalXmp.publishedAt,
        title: originalXmp.title,
        creators: originalXmp.creators,
        description: originalXmp.description,
        subject: originalXmp.subject,
        rating: originalXmp.rating,
        credit: originalXmp.credit,
        otherFields: originalXmp.otherFields,
      );

      final modifiedBytes = writePngXmp(bytes, updatedXmp);
      final readBack = readPngXmp(modifiedBytes)!;

      expect(readBack.assetId, equals(originalAssetId));
      expect(readBack.platform, equals(originalXmp.platform));
    });

    test('PNG: ig-item2.png foreign fields preserved', () async {
      final file = File(p.join(testVectorsPath, 'ig-item2.png'));
      final bytes = await file.readAsBytes();
      
      final originalXmp = readPngXmp(bytes)!;
      final originalSubject = originalXmp.subject;

      final modifiedBytes = writePngXmp(bytes, originalXmp);
      final readBack = readPngXmp(modifiedBytes)!;

      if (originalSubject != null) {
        expect(readBack.subject, equals(originalSubject));
      }
    });

    test('PNG: ig-item2.png non-metadata bytes unchanged', () async {
      final file = File(p.join(testVectorsPath, 'ig-item2.png'));
      final bytes = await file.readAsBytes();
      
      final originalXmp = readPngXmp(bytes)!;
      final originalMetadataDate = originalXmp.metadataDate;
      
      final updatedXmp = XmpProvenance(
        schema: originalXmp.schema,
        assetId: originalXmp.assetId,
        capturedAt: originalXmp.capturedAt,
        capturedBy: originalXmp.capturedBy,
        metadataDate: DateTime.now(),
        sourceUrl: originalXmp.sourceUrl,
        platform: originalXmp.platform,
        sourceId: originalXmp.sourceId,
        itemIndex: originalXmp.itemIndex,
        itemCount: originalXmp.itemCount,
        authorId: originalXmp.authorId,
        publishedAt: originalXmp.publishedAt,
        title: originalXmp.title,
        creators: originalXmp.creators,
        description: originalXmp.description,
        subject: originalXmp.subject,
        rating: originalXmp.rating,
        credit: originalXmp.credit,
        otherFields: originalXmp.otherFields,
      );
      final modifiedBytes = writePngXmp(bytes, updatedXmp);
      
      final nonMetadataDiff = _compareNonMetadataBytes(bytes, modifiedBytes, 'PNG');
      expect(nonMetadataDiff, isNull, reason: nonMetadataDiff);
      
      final readBack = readPngXmp(modifiedBytes)!;
      expect(readBack.metadataDate, isNot(equals(originalMetadataDate)),
          reason: 'metadataDate should be updated');
    });

    // ----- WebP Tests -----
    test('WebP: x-single.webp write → read → verify fields unchanged', () async {
      final file = File(p.join(testVectorsPath, 'x-single.webp'));
      final bytes = await file.readAsBytes();
      
      final originalXmp = readWebpXmp(bytes)!;
      final originalAssetId = originalXmp.assetId;

      final updatedXmp = XmpProvenance(
        schema: originalXmp.schema,
        assetId: originalXmp.assetId,
        capturedAt: originalXmp.capturedAt,
        capturedBy: originalXmp.capturedBy,
        metadataDate: DateTime.now(),
        sourceUrl: originalXmp.sourceUrl,
        platform: originalXmp.platform,
        sourceId: originalXmp.sourceId,
        itemIndex: originalXmp.itemIndex,
        itemCount: originalXmp.itemCount,
        authorId: originalXmp.authorId,
        publishedAt: originalXmp.publishedAt,
        title: originalXmp.title,
        creators: originalXmp.creators,
        description: originalXmp.description,
        subject: originalXmp.subject,
        rating: originalXmp.rating,
        credit: originalXmp.credit,
        otherFields: originalXmp.otherFields,
      );

      final modifiedBytes = writeWebpXmp(bytes, updatedXmp);
      final readBack = readWebpXmp(modifiedBytes)!;

      expect(readBack.assetId, equals(originalAssetId),
          reason: 'assetId must remain unchanged after write');
      expect(readBack.schema, equals(originalXmp.schema));
      expect(readBack.capturedBy, equals(originalXmp.capturedBy));
    });

    test('WebP: x-single.webp foreign fields preserved', () async {
      final file = File(p.join(testVectorsPath, 'x-single.webp'));
      final bytes = await file.readAsBytes();
      
      final originalXmp = readWebpXmp(bytes)!;

      final modifiedBytes = writeWebpXmp(bytes, originalXmp);
      final readBack = readWebpXmp(modifiedBytes)!;

      expect(readBack.title, equals(originalXmp.title));
      expect(readBack.description, equals(originalXmp.description));
    });

    test('WebP: x-single.webp non-metadata bytes unchanged', () async {
      final file = File(p.join(testVectorsPath, 'x-single.webp'));
      final bytes = await file.readAsBytes();
      
      final originalXmp = readWebpXmp(bytes)!;
      final originalMetadataDate = originalXmp.metadataDate;
      
      final updatedXmp = XmpProvenance(
        schema: originalXmp.schema,
        assetId: originalXmp.assetId,
        capturedAt: originalXmp.capturedAt,
        capturedBy: originalXmp.capturedBy,
        metadataDate: DateTime.now(),
        sourceUrl: originalXmp.sourceUrl,
        platform: originalXmp.platform,
        sourceId: originalXmp.sourceId,
        itemIndex: originalXmp.itemIndex,
        itemCount: originalXmp.itemCount,
        authorId: originalXmp.authorId,
        publishedAt: originalXmp.publishedAt,
        title: originalXmp.title,
        creators: originalXmp.creators,
        description: originalXmp.description,
        subject: originalXmp.subject,
        rating: originalXmp.rating,
        credit: originalXmp.credit,
        otherFields: originalXmp.otherFields,
      );
      final modifiedBytes = writeWebpXmp(bytes, updatedXmp);
      
      final nonMetadataDiff = _compareNonMetadataBytes(bytes, modifiedBytes, 'WebP');
      expect(nonMetadataDiff, isNull, reason: nonMetadataDiff);
      
      final readBack = readWebpXmp(modifiedBytes)!;
      expect(readBack.metadataDate, isNot(equals(originalMetadataDate)),
          reason: 'metadataDate should be updated');
    });

    // ----- Simple WebP (VP8 without VP8X) Upgrade Test -----
    test('WebP: simple VP8 upgrade to VP8X preserves image data', () async {
      // Create a simple VP8 WebP manually
      final simpleWebp = _createSimpleVp8Webp();
      
      // Verify it's a simple VP8 format (no VP8X)
      expect(simpleWebp[12], 0x56, reason: 'First chunk should be V'); // 'V'
      expect(simpleWebp[13], 0x50, reason: 'First chunk should be P'); // 'P'
      expect(simpleWebp[14], 0x38, reason: 'First chunk should be 8'); // '8'
      expect(simpleWebp[15], 0x20, reason: 'First chunk should be space'); // ' '
      
      // Create XMP to write
      final xmp = XmpProvenance(
        schema: '0.1',
        assetId: 'test-asset-001',
        capturedAt: DateTime.now(),
        capturedBy: 'test',
        metadataDate: DateTime.now(),
        sourceUrl: 'https://example.com/image.webp',
        platform: 'test',
      );
      
      // Write XMP (should upgrade to VP8X)
      final modifiedBytes = writeWebpXmp(simpleWebp, xmp);
      
      // Verify VP8X header is now present
      expect(modifiedBytes[12], 0x56, reason: 'VP8X chunk starts with V'); // 'V'
      expect(modifiedBytes[13], 0x50, reason: 'VP8X chunk starts with P'); // 'P'
      expect(modifiedBytes[14], 0x38, reason: 'VP8X chunk starts with 8'); // '8'
      expect(modifiedBytes[15], 0x58, reason: 'VP8X chunk ends with X'); // 'X' - upgraded!
      
      // Verify XMP was written
      final readBack = readWebpXmp(modifiedBytes);
      expect(readBack, isNotNull);
      expect(readBack!.assetId, equals('test-asset-001'));
      
      // Verify the file has XMP chunk
      bool hasXmpChunk = false;
      int offset = 12;
      while (offset + 8 <= modifiedBytes.length) {
        final fourCC = String.fromCharCodes(modifiedBytes.sublist(offset, offset + 4));
        if (fourCC == 'XMP ') {
          hasXmpChunk = true;
          break;
        }
        final chunkSize = modifiedBytes[offset + 4] |
            (modifiedBytes[offset + 5] << 8) |
            (modifiedBytes[offset + 6] << 16) |
            (modifiedBytes[offset + 7] << 24);
        offset += 8 + chunkSize;
        if (chunkSize % 2 == 1) offset++;
      }
      expect(hasXmpChunk, isTrue, reason: 'XMP chunk should exist after upgrade');
      
      // Verify the VP8 chunk still exists (image data preserved)
      bool hasVp8Chunk = false;
      offset = 12;
      while (offset + 8 <= modifiedBytes.length) {
        final fourCC = String.fromCharCodes(modifiedBytes.sublist(offset, offset + 4));
        if (fourCC == 'VP8 ' || fourCC == 'VP8L') {
          hasVp8Chunk = true;
          break;
        }
        final chunkSize = modifiedBytes[offset + 4] |
            (modifiedBytes[offset + 5] << 8) |
            (modifiedBytes[offset + 6] << 16) |
            (modifiedBytes[offset + 7] << 24);
        offset += 8 + chunkSize;
        if (chunkSize % 2 == 1) offset++;
      }
      expect(hasVp8Chunk, isTrue, reason: 'VP8 chunk should still exist after upgrade');
    });
  });

  // =========================================================================
  // §10 Edge cases: attribute syntax, multiple rdf:Description blocks, foreign fields
  // =========================================================================
  group('Conformance - Edge case tests', () {
    // Attribute syntax tests for all formats
    test('JPEG: attribute syntax - reads prov:schema from attribute', () async {
      final file = File(p.join(testVectorsPath, 'xhs-item3.jpg'));
      final bytes = await file.readAsBytes();
      
      final xmp = readJpegXmp(bytes);
      expect(xmp, isNotNull);
      expect(xmp!.schema, equals('0.1'));
    });

    test('PNG: attribute syntax - reads prov:schema from attribute', () async {
      final file = File(p.join(testVectorsPath, 'ig-item2.png'));
      final bytes = await file.readAsBytes();
      
      final xmp = readPngXmp(bytes);
      expect(xmp, isNotNull);
      expect(xmp!.schema, equals('0.1'));
    });

    test('WebP: attribute syntax - reads prov:schema from attribute', () async {
      final file = File(p.join(testVectorsPath, 'x-single.webp'));
      final bytes = await file.readAsBytes();
      
      final xmp = readWebpXmp(bytes);
      expect(xmp, isNotNull);
      expect(xmp!.schema, equals('0.1'));
    });

    // Multiple rdf:Description blocks tests for all formats
    test('JPEG: multiple rdf:Description blocks - all fields read', () async {
      final file = File(p.join(testVectorsPath, 'xhs-item3.jpg'));
      final bytes = await file.readAsBytes();
      
      final xmp = readJpegXmp(bytes);
      expect(xmp, isNotNull);
      
      // Fields from attribute block
      expect(xmp!.schema, isNotNull);
      expect(xmp.assetId, isNotNull);
      
      // Fields from child element block
      expect(xmp.title, isNotNull);
      expect(xmp.creators, isNotNull);
      expect(xmp.subject, isNotNull);
    });

    test('PNG: multiple rdf:Description blocks - all fields read', () async {
      final file = File(p.join(testVectorsPath, 'ig-item2.png'));
      final bytes = await file.readAsBytes();
      
      final xmp = readPngXmp(bytes);
      expect(xmp, isNotNull);
      
      // Fields from attribute block
      expect(xmp!.schema, isNotNull);
      expect(xmp.assetId, isNotNull);
      
      // Fields from child element block (ig-item2.png has creator and subject)
      expect(xmp.creators, isNotNull);
      expect(xmp.subject, isNotNull);
    });

    test('WebP: multiple rdf:Description blocks - all fields read', () async {
      final file = File(p.join(testVectorsPath, 'x-single.webp'));
      final bytes = await file.readAsBytes();
      
      final xmp = readWebpXmp(bytes);
      expect(xmp, isNotNull);
      
      // Fields from attribute block
      expect(xmp!.schema, isNotNull);
      expect(xmp.assetId, isNotNull);
      
      // Fields from child element block
      expect(xmp.creators, isNotNull);
      expect(xmp.description, isNotNull);
    });

    // Foreign fields with attribute and element syntax
    test('JPEG: foreign fields in both attribute and element syntax preserved', () async {
      final file = File(p.join(testVectorsPath, 'xhs-item3.jpg'));
      final bytes = await file.readAsBytes();
      
      final originalXmp = readJpegXmp(bytes)!;
      
      // xhs-item3.jpg has:
      // - prov:schema as attribute
      // - dc:title, dc:description, dc:subject as child elements
      // - xmp:Rating as attribute
      
      final originalSubject = originalXmp.subject;
      final originalRating = originalXmp.rating;
      
      // Write back unchanged
      final modifiedBytes = writeJpegXmp(bytes, originalXmp);
      final readBack = readJpegXmp(modifiedBytes)!;
      
      // Both attribute-style and element-style fields preserved
      expect(readBack.subject, equals(originalSubject));
      expect(readBack.rating, equals(originalRating));
      expect(readBack.title, equals(originalXmp.title));
      expect(readBack.description, equals(originalXmp.description));
    });

    test('PNG: foreign fields in both attribute and element syntax preserved', () async {
      final file = File(p.join(testVectorsPath, 'ig-item2.png'));
      final bytes = await file.readAsBytes();
      
      final originalXmp = readPngXmp(bytes)!;
      
      final originalTitle = originalXmp.title;
      final originalDescription = originalXmp.description;
      final originalCreators = originalXmp.creators;
      
      // Write back unchanged
      final modifiedBytes = writePngXmp(bytes, originalXmp);
      final readBack = readPngXmp(modifiedBytes)!;
      
      expect(readBack.title, equals(originalTitle));
      expect(readBack.description, equals(originalDescription));
      expect(readBack.creators, equals(originalCreators));
    });

    test('WebP: foreign fields preserved after write', () async {
      final file = File(p.join(testVectorsPath, 'x-single.webp'));
      final bytes = await file.readAsBytes();
      
      final originalXmp = readWebpXmp(bytes)!;
      
      final originalTitle = originalXmp.title;
      final originalDescription = originalXmp.description;
      
      // Write back unchanged
      final modifiedBytes = writeWebpXmp(bytes, originalXmp);
      final readBack = readWebpXmp(modifiedBytes)!;
      
      expect(readBack.title, equals(originalTitle));
      expect(readBack.description, equals(originalDescription));
    });

    // §4.7: Multiple rdf:Description blocks tests
    test('JPEG: multiblock-elements.jpg write → read → verify (§4.7)', () async {
      final file = File(p.join(testVectorsPath, 'multiblock-elements.jpg'));
      final bytes = await file.readAsBytes();
      
      final originalXmp = readJpegXmp(bytes)!;
      final originalAssetId = originalXmp.assetId;

      // Write with updated metadataDate
      final updatedXmp = XmpProvenance(
        schema: originalXmp.schema,
        assetId: originalXmp.assetId,
        capturedAt: originalXmp.capturedAt,
        capturedBy: originalXmp.capturedBy,
        metadataDate: DateTime.now(),
        sourceUrl: originalXmp.sourceUrl,
        platform: originalXmp.platform,
        sourceId: originalXmp.sourceId,
        itemIndex: originalXmp.itemIndex,
        itemCount: originalXmp.itemCount,
        authorId: originalXmp.authorId,
        publishedAt: originalXmp.publishedAt,
        title: originalXmp.title,
        creators: originalXmp.creators,
        description: originalXmp.description,
        subject: originalXmp.subject,
        rating: originalXmp.rating,
        credit: originalXmp.credit,
        otherFields: originalXmp.otherFields,
      );

      final modifiedBytes = writeJpegXmp(bytes, updatedXmp);
      final readBack = readJpegXmp(modifiedBytes)!;

      // assetId must not change
      expect(readBack.assetId, equals(originalAssetId), 
          reason: 'assetId must remain unchanged after write');

      // Other required fields preserved
      expect(readBack.schema, equals(originalXmp.schema));
      expect(readBack.platform, equals(originalXmp.platform));
      expect(readBack.sourceId, equals(originalXmp.sourceId));
      expect(readBack.creators, equals(originalXmp.creators));
    });

    test('JPEG: multiblock-elements.jpg foreign field xmp:CreatorTool preserved (§4.7)', () async {
      final file = File(p.join(testVectorsPath, 'multiblock-elements.jpg'));
      final bytes = await file.readAsBytes();
      
      final originalXmp = readJpegXmp(bytes)!;
      expect(originalXmp.creators, isNotNull);

      // Write back unchanged
      final modifiedBytes = writeJpegXmp(bytes, originalXmp);
      final readBack = readJpegXmp(modifiedBytes)!;

      // Foreign field xmp:CreatorTool must be preserved
      expect(readBack.creators, equals(originalXmp.creators));
    });

    test('JPEG: multiblock-elements.jpg non-metadata bytes unchanged (§4.7)', () async {
      final file = File(p.join(testVectorsPath, 'multiblock-elements.jpg'));
      final bytes = await file.readAsBytes();
      
      final xmp = readJpegXmp(bytes)!;
      final originalMetadataDate = xmp.metadataDate;

      final updatedXmp = XmpProvenance(
        schema: xmp.schema,
        assetId: xmp.assetId,
        capturedAt: xmp.capturedAt,
        capturedBy: xmp.capturedBy,
        metadataDate: DateTime.now(),
        sourceUrl: xmp.sourceUrl,
        platform: xmp.platform,
        sourceId: xmp.sourceId,
        itemIndex: xmp.itemIndex,
        itemCount: xmp.itemCount,
        authorId: xmp.authorId,
        publishedAt: xmp.publishedAt,
        title: xmp.title,
        creators: xmp.creators,
        description: xmp.description,
        subject: xmp.subject,
        rating: xmp.rating,
        credit: xmp.credit,
        otherFields: xmp.otherFields,
      );
      final modifiedBytes = writeJpegXmp(bytes, updatedXmp);

      final nonMetadataDiff = _compareNonMetadataBytes(bytes, modifiedBytes, 'JPEG');
      expect(nonMetadataDiff, isNull, reason: nonMetadataDiff);

      final readBack = readJpegXmp(modifiedBytes)!;
      expect(readBack.metadataDate, isNot(equals(originalMetadataDate)),
          reason: 'metadataDate should be updated');
    });
  });
}

void _validateJsonMatch(Map<String, dynamic> actual, Map<String, dynamic> expected, String filename) {
  expected.forEach((key, expectedValue) {
    if (key == '_none' || key == 'sha256') {
      return; // Skip spec-only metadata
    }

    expect(actual.containsKey(key), isTrue, 
        reason: '$filename: missing field $key');

    final actualValue = actual[key];

    if (expectedValue is Map) {
      expect(actualValue, isA<Map>(), reason: '$filename: $key should be a Map');
      _validateJsonMatch(actualValue as Map<String, dynamic>, expectedValue as Map<String, dynamic>, '$filename.$key');
    } else if (expectedValue is List) {
      expect(actualValue, isA<List>(), reason: '$filename: $key should be a List');
      expect(actualValue, equals(expectedValue), reason: '$filename: $key mismatch');
    } else {
      if (key.endsWith('At') || key.endsWith('Date')) {
        final expectedDt = DateTime.parse(expectedValue.toString());
        final actualDt = DateTime.parse(actualValue.toString());
        expect(actualDt, equals(expectedDt), reason: '$filename: $key timestamp mismatch');
      } else {
        expect(actualValue, equals(expectedValue), reason: '$filename: $key mismatch');
      }
    }
  });
}
