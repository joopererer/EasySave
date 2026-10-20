// Copyright 2026 EasySave. All rights reserved.
// Tests for C2PA content credentials detection.

import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:easysave/metadata/c2pa_detector.dart';

void main() {
  late String fixturesPath;

  setUpAll(() {
    fixturesPath = p.normalize(p.join(
      Directory.current.path,
      'test',
      'metadata',
      'fixtures',
    ));
  });

  group('C2PA Detection', () {
    test('JPEG: detects C2PA in APP11 JUMBF segment', () async {
      final file = File(p.join(fixturesPath, 'c2pa_jpeg.jpg'));
      if (!file.existsSync()) {
        // Create fixture if it doesn't exist
        final fixture = _createC2paJpeg();
        await file.writeAsBytes(fixture);
      }
      
      final bytes = await file.readAsBytes();
      final status = detectC2pa(bytes, 'JPEG');
      expect(status, equals(C2paStatus.detected));
    });

    test('JPEG: no C2PA in normal file', () async {
      // Use existing test vector
      final file = File(p.join(Directory.current.path, '..', 'docs', 'provenance-spec', 'test-vectors', 'xhs-item3.jpg'));
      if (!file.existsSync()) {
        return; // Skip if test vectors not available
      }
      
      final bytes = await file.readAsBytes();
      final status = detectC2pa(bytes, 'JPEG');
      expect(status, equals(C2paStatus.none));
    });

    test('PNG: detects C2PA caBX chunk', () async {
      final file = File(p.join(fixturesPath, 'c2pa_png.png'));
      if (!file.existsSync()) {
        // Create fixture if it doesn't exist
        final fixture = _createC2paPng();
        await file.writeAsBytes(fixture);
      }
      
      final bytes = await file.readAsBytes();
      final status = detectC2pa(bytes, 'PNG');
      expect(status, equals(C2paStatus.detected));
    });

    test('PNG: no C2PA in normal file', () async {
      // Use existing test vector
      final file = File(p.join(Directory.current.path, '..', 'docs', 'provenance-spec', 'test-vectors', 'ig-item2.png'));
      if (!file.existsSync()) {
        return; // Skip if test vectors not available
      }
      
      final bytes = await file.readAsBytes();
      final status = detectC2pa(bytes, 'PNG');
      expect(status, equals(C2paStatus.none));
    });

    test('WebP: detects C2PA RIFF chunk', () async {
      final file = File(p.join(fixturesPath, 'c2pa_webp.webp'));
      if (!file.existsSync()) {
        // Create fixture if it doesn't exist
        final fixture = _createC2paWebp();
        await file.writeAsBytes(fixture);
      }
      
      final bytes = await file.readAsBytes();
      final status = detectC2pa(bytes, 'WebP');
      expect(status, equals(C2paStatus.detected));
    });

    test('WebP: no C2PA in normal file', () async {
      // Use existing test vector
      final file = File(p.join(Directory.current.path, '..', 'docs', 'provenance-spec', 'test-vectors', 'x-single.webp'));
      if (!file.existsSync()) {
        return; // Skip if test vectors not available
      }
      
      final bytes = await file.readAsBytes();
      final status = detectC2pa(bytes, 'WebP');
      expect(status, equals(C2paStatus.none));
    });

    test('Unknown format returns none', () async {
      final bytes = Uint8List.fromList([0x00, 0x01, 0x02, 0x03]);
      final status = detectC2pa(bytes, 'UNKNOWN');
      expect(status, equals(C2paStatus.none));
    });
  });
}

/// Creates a minimal JPEG with C2PA signature in APP11 JUMBF segment.
Uint8List _createC2paJpeg() {
  final builder = BytesBuilder();
  
  // SOI (Start of Image)
  builder.add([0xFF, 0xD8]);
  
  // APP11 (0xFFEB) with JUMBF containing C2PA label
  // JUMBF structure: UUID + label + data
  const c2paUuid = [
    0x00, 0x1c, 0x7d, 0x0c, // uuid[0-3]
    0x80, 0x00,               // uuid[4-5]
    0x11, 0xea,               // uuid[6-7]
    0xb6, 0x0d,               // uuid[8-9]
    0x17, 0xb8, 0x83, 0xa6, 0x0f, 0x0d // uuid[10-15]
  ];
  
  final label = 'c2pa\x00'; // null-terminated
  final jumbfData = [
    ...c2paUuid,
    ...label.codeUnits,
  ];
  
  // APP11 segment: marker + length + content
  final segmentLength = 2 + jumbfData.length;
  builder.add([0xFF, 0xEB]);
  builder.add([(segmentLength >> 8) & 0xFF, segmentLength & 0xFF]);
  builder.add(jumbfData);
  
  // Minimal JPEG data (SOF + DQT + SOS)
  builder.add([0xFF, 0xC0]); // SOF0
  builder.add([0x00, 0x0B]); // Length = 11
  builder.add([0x08, 0x00, 0x01, 0x00, 0x01, 0x01, 0x11, 0x00]); // 1x1, Y, 1 sample, no quantization
  builder.add([0xFF, 0xDB]); // DQT
  builder.add([0x00, 0x43]); // Length = 67
  builder.add([0x00]); // 8-bit, table 0
  // 64 quantization values (all 1 for simplicity)
  for (int i = 0; i < 64; i++) {
    builder.addByte(1);
  }
  builder.add([0xFF, 0xDA]); // SOS
  builder.add([0x00, 0x08]); // Length = 8
  builder.add([0x01]); // 1 component
  builder.add([0x01, 0x11]); // Y, table 0
  builder.add([0x00, 0x3F, 0x00]); // Spectral selection
  builder.addByte(0x00); // Start of scan
  builder.addByte(0x00); // 1 byte DC
  builder.addByte(0x3F); // 6 bits AC end marker
  builder.addByte(0x00); // 0 bits
  builder.addByte(0x00); // EOB
  
  // EOI (End of Image)
  builder.add([0xFF, 0xD9]);
  
  return builder.toBytes();
}

/// Creates a minimal PNG with C2PA caBX chunk.
Uint8List _createC2paPng() {
  final builder = BytesBuilder();
  
  // PNG signature
  builder.add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  
  // IHDR chunk (1x1 pixel, 8-bit RGB)
  final ihdrData = [0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x00, 0x00, 0x00];
  builder.add(_pngChunk('IHDR', ihdrData));
  
  // caBX chunk (C2PA)
  const caBxData = [0x00, 0x01, 0x02, 0x03]; // Minimal C2PA data
  builder.add(_pngChunk('caBX', caBxData));
  
  // IDAT chunk (minimal compressed data for 1 pixel)
  final idatData = [0x08, 0xD7, 0x63, 0x00, 0x00, 0x00, 0x02, 0x00, 0x01]; // Zlib block, EOI
  builder.add(_pngChunk('IDAT', idatData));
  
  // IEND chunk
  builder.add(_pngChunk('IEND', []));
  
  return builder.toBytes();
}

List<int> _pngChunk(String type, List<int> data) {
  final chunk = <int>[];
  // Length (4 bytes, big-endian)
  chunk.add((data.length >> 24) & 0xFF);
  chunk.add((data.length >> 16) & 0xFF);
  chunk.add((data.length >> 8) & 0xFF);
  chunk.add(data.length & 0xFF);
  // Type
  chunk.addAll(type.codeUnits);
  // Data
  chunk.addAll(data);
  // CRC (simplified - just use type + data bytes)
  var crc = _crc32([...type.codeUnits, ...data]);
  chunk.add((crc >> 24) & 0xFF);
  chunk.add((crc >> 16) & 0xFF);
  chunk.add((crc >> 8) & 0xFF);
  chunk.add(crc & 0xFF);
  return chunk;
}

int _crc32(List<int> data) {
  // Simple CRC-32 implementation
  var crc = 0xFFFFFFFF;
  for (final byte in data) {
    crc ^= byte;
    for (int i = 0; i < 8; i++) {
      if ((crc & 1) != 0) {
        crc = (crc >> 1) ^ 0xEDB88320;
      } else {
        crc >>= 1;
      }
    }
  }
  return crc ^ 0xFFFFFFFF;
}

/// Creates a minimal WebP with C2PA RIFF chunk.
/// WebP structure: RIFF [size] WEBP [chunks...]
/// C2PA is a top-level RIFF chunk, not inside WEBP.
Uint8List _createC2paWebp() {
  // Create a valid WebP with VP8X header
  final builder = BytesBuilder();
  
  // VP8X chunk (Extended format header)
  // Format: VP8X (4) + size (4) + flags (1) + reserved (3) + width (3) + height (3)
  final vp8xData = <int>[
    0x00, // Flags: 0 (no features)
    0x00, 0x00, 0x00, // Reserved
    0x01, 0x00, 0x01, 0x00, // 1x1 dimensions
  ];
  
  // Minimal VP8 lossy bitstream (1x1 pixel)
  final vp8Data = <int>[
    0x9D, 0x01, 0x2A, // Frame tag (key frame, version 0)
    0x10, 0x00, 0x10, 0x00, // Width/Height
    0x80, 0x80, 0x80, // Minimal partition
    0x00, 0x00, 0x00, // End marker
  ];
  
  // Build the actual chunks
  final chunks = BytesBuilder();
  
  // VP8X chunk
  chunks.add([0x56, 0x50, 0x38, 0x58]); // 'VP8X'
  chunks.add([vp8xData.length & 0xFF, (vp8xData.length >> 8) & 0xFF, (vp8xData.length >> 16) & 0xFF, (vp8xData.length >> 24) & 0xFF]);
  chunks.add(vp8xData);
  
  // VP8 chunk
  chunks.add([0x56, 0x50, 0x38, 0x20]); // 'VP8 '
  final vp8Len = vp8Data.length;
  chunks.add([vp8Len & 0xFF, (vp8Len >> 8) & 0xFF, (vp8Len >> 16) & 0xFF, (vp8Len >> 24) & 0xFF]);
  chunks.add(vp8Data);
  // Padding byte if odd
  if (vp8Len % 2 == 1) chunks.addByte(0x00);
  
  // C2PA chunk (the one we're testing)
  const c2paData = [0x01, 0x00]; // Minimal C2PA manifest data
  chunks.add([0x43, 0x32, 0x50, 0x41]); // 'C2PA'
  chunks.add([c2paData.length & 0xFF, (c2paData.length >> 8) & 0xFF, (c2paData.length >> 16) & 0xFF, (c2paData.length >> 24) & 0xFF]);
  chunks.add(c2paData);
  
  final chunkBytes = chunks.toBytes();
  final fileSize = 4 + chunkBytes.length; // 'WEBP' + chunks
  
  // Build final WebP file
  final result = BytesBuilder();
  result.add([0x52, 0x49, 0x46, 0x46]); // 'RIFF'
  result.add([fileSize & 0xFF, (fileSize >> 8) & 0xFF, (fileSize >> 16) & 0xFF, (fileSize >> 24) & 0xFF]);
  result.add([0x57, 0x45, 0x42, 0x50]); // 'WEBP'
  result.add(chunkBytes);
  
  return result.toBytes();
}
