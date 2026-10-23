// Copyright 2026 EasySave. All rights reserved.
// Truncated header parsing tests (Phase 2 Task 2).
//
// Verifies that data extracted using the native layer rules (MediaHeaderReader)
// parses to the exact same XmpProvenance as parsing the full file.
//
// Native rules:
// - JPEG: first 128 KB of the file.
// - PNG: chunk walk stopping at the XMP iTXt chunk (signature + iTXt chunk with CRC),
//   skipping non-XMP iTXt chunks, stopping at IDAT/IEND.
// - WebP: RIFF walk stopping at the 'XMP ' chunk (RIFF header + XMP chunk).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provenance_dart/provenance_dart.dart';

/// Simulates native MediaHeaderReader.readJpeg (reads up to 128KB).
Uint8List simulateNativeJpegRead(Uint8List bytes) {
  const maxBytes = 128 * 1024;
  if (bytes.length <= maxBytes) return bytes;
  return Uint8List.sublistView(bytes, 0, maxBytes);
}

/// Simulates native MediaHeaderReader.readPng:
/// - Checks 8-byte PNG signature
/// - Walks chunks
/// - If IDAT or IEND reached without XMP, returns empty bytes (null on native)
/// - If iTXt chunk found with keyword "XML:com.adobe.xmp", returns PNG signature + iTXt chunk (data + 4-byte CRC)
/// - Skips other chunks (including non-XMP iTXt chunks)
Uint8List simulateNativePngRead(Uint8List bytes) {
  const pngSig = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  if (bytes.length < 8) return Uint8List(0);
  for (int i = 0; i < 8; i++) {
    if (bytes[i] != pngSig[i]) return Uint8List(0);
  }

  const maxWalkBytes = 4 * 1024 * 1024;
  final keywordBytes = utf8.encode('XML:com.adobe.xmp');

  int walked = 0;
  int offset = 8;

  while (walked < maxWalkBytes && offset + 8 <= bytes.length) {
    final length = (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
    if (length < 0) break;

    final type = String.fromCharCodes(bytes.sublist(offset + 4, offset + 8));

    if (type == 'IDAT' || type == 'IEND') {
      return Uint8List(0);
    }

    if (type == 'iTXt') {
      final totalChunkLen = 8 + length + 4;
      if (offset + totalChunkLen > bytes.length) break;

      final dataStart = offset + 8;
      // Check keyword: "XML:com.adobe.xmp\0"
      bool matchesKeyword = false;
      if (length >= keywordBytes.length + 1) {
        matchesKeyword = true;
        for (int i = 0; i < keywordBytes.length; i++) {
          if (bytes[dataStart + i] != keywordBytes[i]) {
            matchesKeyword = false;
            break;
          }
        }
        if (matchesKeyword && bytes[dataStart + keywordBytes.length] != 0) {
          matchesKeyword = false;
        }
      }

      if (matchesKeyword) {
        // Return PNG signature + this complete iTXt chunk (header + data + CRC)
        final result = BytesBuilder(copy: false)
          ..add(bytes.sublist(0, 8))
          ..add(bytes.sublist(offset, offset + totalChunkLen));
        return result.toBytes();
      }

      walked += totalChunkLen;
      offset += totalChunkLen;
      continue;
    }

    // Skip chunk payload and its 4-byte CRC
    final totalChunkLen = 8 + length + 4;
    offset += totalChunkLen;
    walked += totalChunkLen;
  }

  return Uint8List(0);
}

/// Simulates native MediaHeaderReader.readWebp:
/// - Checks 12-byte WEBP header (RIFF....WEBP)
/// - Walks RIFF chunks
/// - If 'XMP ' chunk found, returns RIFF header + XMP chunk header + data
Uint8List simulateNativeWebpRead(Uint8List bytes) {
  if (bytes.length < 12) return Uint8List(0);
  final riff = String.fromCharCodes(bytes.sublist(0, 4));
  final webp = String.fromCharCodes(bytes.sublist(8, 12));
  if (riff != 'RIFF' || webp != 'WEBP') return Uint8List(0);

  const maxWalkBytes = 4 * 1024 * 1024;
  int walked = 0;
  int offset = 12;

  while (walked < maxWalkBytes && offset + 8 <= bytes.length) {
    final fourCc = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final size = bytes[offset + 4] |
        (bytes[offset + 5] << 8) |
        (bytes[offset + 6] << 16) |
        (bytes[offset + 7] << 24);
    if (size < 0) break;

    if (fourCc == 'XMP ') {
      if (offset + 8 + size > bytes.length) break;
      final result = BytesBuilder(copy: false)
        ..add(bytes.sublist(0, 12))
        ..add(bytes.sublist(offset, offset + 8 + size));
      return result.toBytes();
    }

    final padding = (size % 2 == 1) ? 1 : 0;
    offset += 8 + size + padding;
    walked += 8 + size + padding;
  }

  return Uint8List(0);
}

/// Simulates native MediaHeaderReader.readMp4:
/// - Checks 8-byte 'ftyp' box
/// - Walks top-level boxes (handles 32-bit, 64-bit largesize, size 0)
/// - Truncation stops and keeps prior complete boxes
/// - Extracts complete XMP uuid boxes (UUID BE7ACFCB-97A9-42E8-9C71-999491E3AFAC)
/// - Skips boxes with payload > 16MB (maxMp4XmpBytes)
/// - Returns concatenated complete XMP uuid boxes, or null if none
Uint8List? simulateNativeMp4Read(Uint8List bytes) {
  if (bytes.length < 8) return null;
  if (bytes[4] != 0x66 || bytes[5] != 0x74 || bytes[6] != 0x79 || bytes[7] != 0x70) {
    return null;
  }

  const maxMp4XmpBytes = 16 * 1024 * 1024;
  final xmpUuid = [
    0xBE, 0x7A, 0xCF, 0xCB, 0x97, 0xA9, 0x42, 0xE8, //
    0x9C, 0x71, 0x99, 0x94, 0x91, 0xE3, 0xAF, 0xAC,
  ];

  final fileSize = bytes.length;
  var pos = 0;
  final xmpBoxes = <Uint8List>[];

  while (pos + 8 <= fileSize) {
    final size32 = (bytes[pos] << 24) |
        (bytes[pos + 1] << 16) |
        (bytes[pos + 2] << 8) |
        bytes[pos + 3];
    final type = String.fromCharCodes(bytes.sublist(pos + 4, pos + 8));

    int headerSize;
    int totalBoxSize;

    if (size32 == 1) {
      if (pos + 16 > fileSize) break;
      int largeSize = 0;
      for (int i = 0; i < 8; i++) {
        largeSize = (largeSize << 8) | bytes[pos + 8 + i];
      }
      if (largeSize < 16) break;
      headerSize = 16;
      totalBoxSize = largeSize;
    } else if (size32 == 0) {
      headerSize = 8;
      totalBoxSize = fileSize - pos;
    } else if (size32 < 8) {
      break;
    } else {
      headerSize = 8;
      totalBoxSize = size32;
    }

    if (totalBoxSize <= 0 || pos + totalBoxSize > fileSize) {
      break;
    }

    if (type == 'uuid' && totalBoxSize >= headerSize + 16) {
      bool isMatch = true;
      for (int i = 0; i < 16; i++) {
        if (bytes[pos + headerSize + i] != xmpUuid[i]) {
          isMatch = false;
          break;
        }
      }
      if (isMatch) {
        final payloadSize = totalBoxSize - headerSize;
        if (payloadSize > 0 && payloadSize <= maxMp4XmpBytes) {
          xmpBoxes.add(bytes.sublist(pos, pos + totalBoxSize));
        }
      }
    }

    pos += totalBoxSize;
  }

  if (xmpBoxes.isEmpty) return null;
  final builder = BytesBuilder(copy: false);
  for (final box in xmpBoxes) {
    builder.add(box);
  }
  return builder.toBytes();
}

final List<int> _crcTable = () {
  final table = List<int>.filled(256, 0);
  for (int n = 0; n < 256; n++) {
    int c = n;
    for (int k = 0; k < 8; k++) {
      if ((c & 1) != 0) {
        c = 0xEDB88320 ^ (c >>> 1);
      } else {
        c = c >>> 1;
      }
    }
    table[n] = c;
  }
  return table;
}();

/// Standard CRC-32 for building test PNG chunks.
int _crc32(List<int> data) {
  int crc = 0xFFFFFFFF;
  for (final byte in data) {
    crc = _crcTable[(crc ^ byte) & 0xFF] ^ (crc >>> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

/// Encodes a complete PNG chunk (length + type + data + CRC).
Uint8List _makePngChunk(String type, List<int> data) {
  final builder = BytesBuilder(copy: false);
  final len = data.length;
  builder.add([
    (len >> 24) & 0xFF,
    (len >> 16) & 0xFF,
    (len >> 8) & 0xFF,
    len & 0xFF,
  ]);
  final typeBytes = ascii.encode(type);
  builder.add(typeBytes);
  builder.add(data);

  final crcData = <int>[...typeBytes, ...data];
  final crc = _crc32(crcData);
  builder.add([
    (crc >> 24) & 0xFF,
    (crc >> 16) & 0xFF,
    (crc >> 8) & 0xFF,
    crc & 0xFF,
  ]);
  return builder.toBytes();
}

/// Builds an uncompressed iTXt chunk payload.
Uint8List _makeItxtData(String keyword, String text) {
  final builder = BytesBuilder(copy: false);
  builder.add(ascii.encode(keyword));
  builder.addByte(0); // null separator
  builder.addByte(0); // compression flag = 0
  builder.addByte(0); // compression method = 0
  builder.addByte(0); // language tag null
  builder.addByte(0); // translated keyword null
  builder.add(utf8.encode(text));
  return builder.toBytes();
}

void _assertProvenanceEquals(XmpProvenance? actual, XmpProvenance? expected, {required String file}) {
  if (expected == null) {
    expect(actual, isNull, reason: '$file: expected null provenance');
    return;
  }
  expect(actual, isNotNull, reason: '$file: expected non-null provenance');
  expect(actual!.assetId, equals(expected.assetId), reason: '$file: assetId mismatch');
  expect(actual.platform, equals(expected.platform), reason: '$file: platform mismatch');
  expect(actual.sourceId, equals(expected.sourceId), reason: '$file: sourceId mismatch');
  expect(actual.sourceUrl, equals(expected.sourceUrl), reason: '$file: sourceUrl mismatch');
  expect(actual.capturedAt, equals(expected.capturedAt), reason: '$file: capturedAt mismatch');
  expect(actual.capturedBy, equals(expected.capturedBy), reason: '$file: capturedBy mismatch');
  expect(actual.title, equals(expected.title), reason: '$file: title mismatch');
  expect(actual.description, equals(expected.description), reason: '$file: description mismatch');
  expect(actual.credit, equals(expected.credit), reason: '$file: credit mismatch');
  expect(actual.itemIndex, equals(expected.itemIndex), reason: '$file: itemIndex mismatch');
  expect(actual.itemCount, equals(expected.itemCount), reason: '$file: itemCount mismatch');
  expect(actual.authorId, equals(expected.authorId), reason: '$file: authorId mismatch');
  expect(actual.creators, equals(expected.creators), reason: '$file: creators mismatch');
  expect(actual.publishedAt, equals(expected.publishedAt), reason: '$file: publishedAt mismatch');
}

void main() {
  final vectorsDir = p.canonicalize(p.join(Directory.current.path, '..', 'docs', 'provenance-spec', 'test-vectors'));

  group('Truncated Header Parsing (Phase 2 Item 2)', () {
    test('JPEG test vectors: truncated 128KB header yields identical provenance', () {
      final jpegFiles = [
        'baidupan-single.jpg',
        'exif-before-xmp.jpg',
        'multiblock-elements.jpg',
        'xhs-item3.jpg',
      ];

      for (final name in jpegFiles) {
        final file = File(p.join(vectorsDir, name));
        expect(file.existsSync(), isTrue, reason: 'Test vector $name must exist');
        final fullBytes = file.readAsBytesSync();

        final fullProvenance = readJpegXmp(fullBytes);
        expect(fullProvenance, isNotNull, reason: '$name full file should have provenance');

        final truncatedBytes = simulateNativeJpegRead(fullBytes);
        final truncatedProvenance = readJpegXmp(truncatedBytes);

        _assertProvenanceEquals(truncatedProvenance, fullProvenance, file: name);
      }
    });

    test('JPEG without metadata: truncated 128KB header yields null', () {
      final file = File(p.join(vectorsDir, 'no-metadata.jpg'));
      expect(file.existsSync(), isTrue);
      final fullBytes = file.readAsBytesSync();

      final fullProvenance = readJpegXmp(fullBytes);
      expect(fullProvenance, isNull);

      final truncatedBytes = simulateNativeJpegRead(fullBytes);
      final truncatedProvenance = readJpegXmp(truncatedBytes);
      expect(truncatedProvenance, isNull);
    });

    test('PNG test vector: truncated iTXt chunk yields identical provenance', () {
      final file = File(p.join(vectorsDir, 'ig-item2.png'));
      expect(file.existsSync(), isTrue, reason: 'ig-item2.png must exist');
      final fullBytes = file.readAsBytesSync();

      final fullProvenance = readPngXmp(fullBytes);
      expect(fullProvenance, isNotNull, reason: 'ig-item2.png full file should have provenance');

      final truncatedBytes = simulateNativePngRead(fullBytes);
      expect(truncatedBytes.isNotEmpty, isTrue, reason: 'Native PNG reader should find XMP chunk');

      final truncatedProvenance = readPngXmp(truncatedBytes);
      _assertProvenanceEquals(truncatedProvenance, fullProvenance, file: 'ig-item2.png');
    });

    test('WebP test vector: truncated XMP chunk yields identical provenance', () {
      final file = File(p.join(vectorsDir, 'x-single.webp'));
      expect(file.existsSync(), isTrue, reason: 'x-single.webp must exist');
      final fullBytes = file.readAsBytesSync();

      final fullProvenance = readWebpXmp(fullBytes);
      expect(fullProvenance, isNotNull, reason: 'x-single.webp full file should have provenance');

      final truncatedBytes = simulateNativeWebpRead(fullBytes);
      expect(truncatedBytes.isNotEmpty, isTrue, reason: 'Native WebP reader should find XMP chunk');

      final truncatedProvenance = readWebpXmp(truncatedBytes);
      _assertProvenanceEquals(truncatedProvenance, fullProvenance, file: 'x-single.webp');
    });

    test('PNG with non-XMP iTXt preceding XMP chunk: reader skips it and reads XMP', () {
      // Load base ig-item2.png
      final file = File(p.join(vectorsDir, 'ig-item2.png'));
      final fullBytes = file.readAsBytesSync();
      final expectedProvenance = readPngXmp(fullBytes);
      expect(expectedProvenance, isNotNull);

      // Locate IHDR and the XMP iTXt chunk in ig-item2.png
      // ig-item2.png structure:
      // [0..8]: signature
      // [8..33]: IHDR (length=13, type="IHDR", data=13, crc=4 -> 25 bytes)
      // [33..end of iTXt]: iTXt chunk
      // followed by IDAT, IEND.
      int offset = 8;
      int? ihdrEnd;
      int? xmpChunkStart;
      int? xmpChunkEnd;

      while (offset + 8 <= fullBytes.length) {
        final length = (fullBytes[offset] << 24) |
            (fullBytes[offset + 1] << 16) |
            (fullBytes[offset + 2] << 8) |
            fullBytes[offset + 3];
        final type = String.fromCharCodes(fullBytes.sublist(offset + 4, offset + 8));
        final chunkEnd = offset + 12 + length;
        if (type == 'IHDR') {
          ihdrEnd = chunkEnd;
        } else if (type == 'iTXt') {
          xmpChunkStart = offset;
          xmpChunkEnd = chunkEnd;
          break;
        }
        offset = chunkEnd;
      }

      expect(ihdrEnd, isNotNull);
      expect(xmpChunkStart, isNotNull);
      expect(xmpChunkEnd, isNotNull);

      // Create an extraneous iTXt chunk with keyword "Comment"
      final commentChunk = _makePngChunk('iTXt', _makeItxtData('Comment', 'Generated author note before XMP'));

      // Construct PNG with:
      // Signature + IHDR + commentChunk + original XMP iTXt + remainder (IDAT, IEND)
      final syntheticPng = (BytesBuilder(copy: false)
        ..add(fullBytes.sublist(0, ihdrEnd!))
        ..add(commentChunk)
        ..add(fullBytes.sublist(xmpChunkStart!)))
        .toBytes();

      // Verify full synthetic PNG can be parsed by provenance_dart
      final fullSyntheticProvenance = readPngXmp(syntheticPng);
      _assertProvenanceEquals(fullSyntheticProvenance, expectedProvenance, file: 'synthetic-full');

      // Verify native simulation extracts the correct XMP chunk (skipping "Comment")
      final truncatedBytes = simulateNativePngRead(syntheticPng);
      expect(truncatedBytes.isNotEmpty, isTrue, reason: 'simulateNativePngRead should find XMP chunk despite preceding iTXt');

      final truncatedProvenance = readPngXmp(truncatedBytes);
      _assertProvenanceEquals(truncatedProvenance, expectedProvenance, file: 'synthetic-truncated');
    });

    test('PNG without XMP (stops at IDAT/IEND): returns empty / null', () {
      // Create minimal PNG: Signature + IHDR + IDAT + IEND
      final builder = BytesBuilder(copy: false)
        ..add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        ..add(_makePngChunk('IHDR', List.filled(13, 0)))
        ..add(_makePngChunk('IDAT', [1, 2, 3]))
        ..add(_makePngChunk('IEND', []));
      final pngNoXmp = builder.toBytes();

      final truncated = simulateNativePngRead(pngNoXmp);
      expect(truncated.isEmpty, isTrue);
    });

    test('All 12 spec MP4/MOV test vectors parse identically from native extracted bytes', () {
      final specDir = Directory(p.join(Directory.current.path, '..', 'docs', 'provenance-spec', 'test-vectors'));
      expect(specDir.existsSync(), isTrue, reason: 'test-vectors dir must exist');

      final videoFiles = [
        'local-video.mp4',
        'mov-no-xmp.mov',
        'mov-xmp-uuid.mov',
        'mp4-64bit-box.mp4',
        'mp4-interrupted-append.mp4',
        'mp4-mdat-uuid-noise.mp4',
        'mp4-multiple-xmp.mp4',
        'mp4-no-xmp.mp4',
        'mp4-size-zero-mdat.mp4',
        'mp4-truncated-mdat.mp4',
        'mp4-truncated-xmp.mp4',
        'mp4-xmp-uuid.mp4',
      ];

      for (final filename in videoFiles) {
        final file = File(p.join(specDir.path, filename));
        expect(file.existsSync(), isTrue, reason: '$filename must exist');
        final fullBytes = file.readAsBytesSync();

        final expFile = File(p.join(specDir.path, '$filename.expected.json'));
        final expJson = jsonDecode(expFile.readAsStringSync()) as Map<String, dynamic>;
        final expectNoXmp = expJson.containsKey('_none') || filename == 'local-video.mp4';

        final extractedBytes = simulateNativeMp4Read(fullBytes);

        if (expectNoXmp) {
          expect(extractedBytes, isNull, reason: '$filename should return null extracted bytes');
          final parsed = readMp4Xmp(extractedBytes ?? Uint8List(0));
          expect(parsed, isNull, reason: '$filename should have no XMP');
        } else {
          expect(extractedBytes, isNotNull, reason: '$filename should extract XMP boxes');
          final extractedProvenance = readMp4Xmp(extractedBytes!);
          expect(extractedProvenance, isNotNull, reason: '$filename extracted bytes must parse into XmpProvenance');

          final fullFileProvenance = readMp4Xmp(fullBytes);
          _assertProvenanceEquals(extractedProvenance, fullFileProvenance, file: filename);

          if (expJson.containsKey('assetId')) {
            expect(extractedProvenance!.assetId, equals(expJson['assetId']));
          }
          if (expJson.containsKey('title')) {
            expect(extractedProvenance!.title, equals(expJson['title']));
          }
        }
      }
    });

    test('MP4 non-ftyp headers return null', () {
      final nonMp4 = Uint8List(32);
      expect(simulateNativeMp4Read(nonMp4), isNull);

      final pngHeader = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      expect(simulateNativeMp4Read(pngHeader), isNull);
    });
  });
}

