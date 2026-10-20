// Copyright 2026 EasySave. All rights reserved.
// Comprehensive XMP read/write tests for JPEG, PNG, WebP

import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:easysave/metadata/xmp_model.dart';
import 'package:easysave/metadata/xmp_jpeg.dart';
import 'package:easysave/metadata/xmp_png.dart';
import 'package:easysave/metadata/xmp_webp.dart';

void main() {
  group('JPEG XMP', () {
    test('preserves foreign fields', () {
      // Create JPEG with XMP containing photoshop:Headline
      final minimalJpeg = _minimalJpeg();
      
      final xmp1 = XmpProvenance(
        schema: '0.1',
        assetId: 'asset-1',
        capturedAt: DateTime.utc(2026, 10, 20),
        capturedBy: 'EasySave',
        metadataDate: DateTime.utc(2026, 10, 20),
        sourceUrl: 'https://example.com/test',
        platform: 'web',
        sourceId: 'test',
        otherFields: {'photoshop:Headline': 'Original Headline'},
      );
      
      final withXmp1 = writeJpegXmp(minimalJpeg, xmp1);
      
      // Write new XMP without photoshop:Headline
      final xmp2 = XmpProvenance(
        schema: '0.1',
        assetId: 'asset-1',
        capturedAt: DateTime.utc(2026, 10, 20, 1),
        capturedBy: 'EasySave',
        metadataDate: DateTime.utc(2026, 10, 20, 1),
        sourceUrl: 'https://example.com/test',
        platform: 'web',
        sourceId: 'test',
      );
      
      final withXmp2 = writeJpegXmp(withXmp1, xmp2);
      final read = readJpegXmp(withXmp2);
      
      expect(read, isNotNull);
      expect(read!.otherFields['photoshop:Headline'], 'Original Headline');
    });
    
    test('preserves assetId', () {
      final minimalJpeg = _minimalJpeg();
      
      final xmp1 = XmpProvenance(
        schema: '0.1',
        assetId: 'original-asset-id',
        capturedAt: DateTime.utc(2026, 10, 20),
        capturedBy: 'EasySave',
        metadataDate: DateTime.utc(2026, 10, 20),
        sourceUrl: 'https://example.com/test',
        platform: 'web',
        sourceId: 'test',
      );
      
      final withXmp1 = writeJpegXmp(minimalJpeg, xmp1);
      
      // Try to overwrite with new assetId
      final xmp2 = XmpProvenance(
        schema: '0.1',
        assetId: 'new-asset-id',
        capturedAt: DateTime.utc(2026, 10, 20, 1),
        capturedBy: 'EasySave',
        metadataDate: DateTime.utc(2026, 10, 20, 1),
        sourceUrl: 'https://example.com/test',
        platform: 'web',
        sourceId: 'test',
      );
      
      final withXmp2 = writeJpegXmp(withXmp1, xmp2);
      final read = readJpegXmp(withXmp2);
      
      expect(read, isNotNull);
      expect(read!.assetId, 'original-asset-id');
    });
    
    test('byte preservation outside metadata segment', () {
      final jpeg = _minimalJpeg();
      
      final xmp = XmpProvenance(
        schema: '0.1',
        assetId: 'test',
        capturedAt: DateTime.utc(2026, 10, 20),
        capturedBy: 'EasySave',
        metadataDate: DateTime.utc(2026, 10, 20),
        sourceUrl: 'https://example.com/test',
        platform: 'web',
        sourceId: 'test',
      );
      
      final withXmp = writeJpegXmp(jpeg, xmp);
      
      // Extract scan data (after SOI, APP0, SOF0, SOS headers, before EOI)
      // Original: SOI(2) + APP0(2+16) + SOF0(2+11) + SOS(2+8) + EOI(2) = 43 bytes
      // Scan data is empty in minimal JPEG, but we check SOI and structure
      expect(withXmp[0], 0xFF);
      expect(withXmp[1], 0xD8); // SOI preserved
      
      // Last 2 bytes should be EOI
      expect(withXmp[withXmp.length - 2], 0xFF);
      expect(withXmp[withXmp.length - 1], 0xD9);
    });
  });
  
  group('PNG XMP', () {
    test('preserves foreign fields', () {
      final minimalPng = _minimalPng();
      
      final xmp1 = XmpProvenance(
        schema: '0.1',
        assetId: 'asset-1',
        capturedAt: DateTime.utc(2026, 10, 20),
        capturedBy: 'EasySave',
        metadataDate: DateTime.utc(2026, 10, 20),
        sourceUrl: 'https://example.com/test',
        platform: 'web',
        sourceId: 'test',
        otherFields: {'photoshop:Headline': 'PNG Headline'},
      );
      
      final withXmp1 = writePngXmp(minimalPng, xmp1);
      
      final xmp2 = XmpProvenance(
        schema: '0.1',
        assetId: 'asset-1',
        capturedAt: DateTime.utc(2026, 10, 20, 1),
        capturedBy: 'EasySave',
        metadataDate: DateTime.utc(2026, 10, 20, 1),
        sourceUrl: 'https://example.com/test',
        platform: 'web',
        sourceId: 'test',
      );
      
      final withXmp2 = writePngXmp(withXmp1, xmp2);
      final read = readPngXmp(withXmp2);
      
      expect(read, isNotNull);
      expect(read!.otherFields['photoshop:Headline'], 'PNG Headline');
    });
    
    test('preserves assetId', () {
      final minimalPng = _minimalPng();
      
      final xmp1 = XmpProvenance(
        schema: '0.1',
        assetId: 'original-png-id',
        capturedAt: DateTime.utc(2026, 10, 20),
        capturedBy: 'EasySave',
        metadataDate: DateTime.utc(2026, 10, 20),
        sourceUrl: 'https://example.com/test',
        platform: 'web',
        sourceId: 'test',
      );
      
      final withXmp1 = writePngXmp(minimalPng, xmp1);
      
      final xmp2 = XmpProvenance(
        schema: '0.1',
        assetId: 'new-png-id',
        capturedAt: DateTime.utc(2026, 10, 20, 1),
        capturedBy: 'EasySave',
        metadataDate: DateTime.utc(2026, 10, 20, 1),
        sourceUrl: 'https://example.com/test',
        platform: 'web',
        sourceId: 'test',
      );
      
      final withXmp2 = writePngXmp(withXmp1, xmp2);
      final read = readPngXmp(withXmp2);
      
      expect(read, isNotNull);
      expect(read!.assetId, 'original-png-id');
    });
    
    test('byte preservation outside metadata chunk', () {
      final png = _minimalPng();
      
      final xmp = XmpProvenance(
        schema: '0.1',
        assetId: 'test',
        capturedAt: DateTime.utc(2026, 10, 20),
        capturedBy: 'EasySave',
        metadataDate: DateTime.utc(2026, 10, 20),
        sourceUrl: 'https://example.com/test',
        platform: 'web',
        sourceId: 'test',
      );
      
      final withXmp = writePngXmp(png, xmp);
      
      // PNG signature preserved
      expect(withXmp.sublist(0, 8), png.sublist(0, 8));
      
      // IEND chunk preserved (last 12 bytes)
      expect(withXmp.sublist(withXmp.length - 12), png.sublist(png.length - 12));
    });
  });
  
  group('WebP XMP', () {
    test('reads XMP from extended format', () {
      final webpExtended = _minimalWebpExtended();
      
      final xmp = XmpProvenance(
        schema: '0.1',
        assetId: 'webp-test',
        capturedAt: DateTime.utc(2026, 10, 20),
        capturedBy: 'EasySave',
        metadataDate: DateTime.utc(2026, 10, 20),
        sourceUrl: 'https://example.com/test',
        platform: 'web',
        sourceId: 'test',
      );
      
      final withXmp = writeWebpXmp(webpExtended, xmp);
      final read = readWebpXmp(withXmp);
      
      expect(read, isNotNull);
      expect(read!.assetId, 'webp-test');
    });
    
    test('upgrades simple VP8 format to VP8X', () {
      final webpSimple = _minimalWebpVp8();
      
      final xmp = XmpProvenance(
        schema: '0.1',
        assetId: 'vp8-upgrade',
        capturedAt: DateTime.utc(2026, 10, 20),
        capturedBy: 'EasySave',
        metadataDate: DateTime.utc(2026, 10, 20),
        sourceUrl: 'https://example.com/test',
        platform: 'web',
        sourceId: 'test',
      );
      
      final withXmp = writeWebpXmp(webpSimple, xmp);
      
      // Verify VP8X chunk exists
      final vp8xSig = String.fromCharCodes(withXmp.sublist(12, 16));
      expect(vp8xSig, 'VP8X');
      
      // Verify XMP flag is set (bit 2 of flags byte at offset 20)
      expect(withXmp[20] & 0x04, 0x04);
      
      final read = readWebpXmp(withXmp);
      expect(read, isNotNull);
      expect(read!.assetId, 'vp8-upgrade');
    });
    
    test('upgrades simple VP8L format to VP8X', () {
      final webpLossless = _minimalWebpVp8l();
      
      final xmp = XmpProvenance(
        schema: '0.1',
        assetId: 'vp8l-upgrade',
        capturedAt: DateTime.utc(2026, 10, 20),
        capturedBy: 'EasySave',
        metadataDate: DateTime.utc(2026, 10, 20),
        sourceUrl: 'https://example.com/test',
        platform: 'web',
        sourceId: 'test',
      );
      
      final withXmp = writeWebpXmp(webpLossless, xmp);
      
      // Verify VP8X chunk exists
      final vp8xSig = String.fromCharCodes(withXmp.sublist(12, 16));
      expect(vp8xSig, 'VP8X');
      
      final read = readWebpXmp(withXmp);
      expect(read, isNotNull);
      expect(read!.assetId, 'vp8l-upgrade');
    });
    
    test('preserves foreign fields in WebP', () {
      final webp = _minimalWebpVp8();
      
      final xmp1 = XmpProvenance(
        schema: '0.1',
        assetId: 'asset-1',
        capturedAt: DateTime.utc(2026, 10, 20),
        capturedBy: 'EasySave',
        metadataDate: DateTime.utc(2026, 10, 20),
        sourceUrl: 'https://example.com/test',
        platform: 'web',
        sourceId: 'test',
        otherFields: {'photoshop:Headline': 'WebP Headline'},
      );
      
      final withXmp1 = writeWebpXmp(webp, xmp1);
      
      final xmp2 = XmpProvenance(
        schema: '0.1',
        assetId: 'asset-1',
        capturedAt: DateTime.utc(2026, 10, 20, 1),
        capturedBy: 'EasySave',
        metadataDate: DateTime.utc(2026, 10, 20, 1),
        sourceUrl: 'https://example.com/test',
        platform: 'web',
        sourceId: 'test',
      );
      
      final withXmp2 = writeWebpXmp(withXmp1, xmp2);
      final read = readWebpXmp(withXmp2);
      
      expect(read, isNotNull);
      expect(read!.otherFields['photoshop:Headline'], 'WebP Headline');
    });
    
    test('preserves assetId in WebP', () {
      final webp = _minimalWebpVp8();
      
      final xmp1 = XmpProvenance(
        schema: '0.1',
        assetId: 'original-webp-id',
        capturedAt: DateTime.utc(2026, 10, 20),
        capturedBy: 'EasySave',
        metadataDate: DateTime.utc(2026, 10, 20),
        sourceUrl: 'https://example.com/test',
        platform: 'web',
        sourceId: 'test',
      );
      
      final withXmp1 = writeWebpXmp(webp, xmp1);
      
      final xmp2 = XmpProvenance(
        schema: '0.1',
        assetId: 'new-webp-id',
        capturedAt: DateTime.utc(2026, 10, 20, 1),
        capturedBy: 'EasySave',
        metadataDate: DateTime.utc(2026, 10, 20, 1),
        sourceUrl: 'https://example.com/test',
        platform: 'web',
        sourceId: 'test',
      );
      
      final withXmp2 = writeWebpXmp(withXmp1, xmp2);
      final read = readWebpXmp(withXmp2);
      
      expect(read, isNotNull);
      expect(read!.assetId, 'original-webp-id');
    });
    
    test('byte preservation in VP8 bitstream', () {
      final webp = _minimalWebpVp8();
      
      // Extract original VP8 chunk data
      final originalVp8 = _extractChunk(webp, 'VP8 ');
      
      final xmp = XmpProvenance(
        schema: '0.1',
        assetId: 'test',
        capturedAt: DateTime.utc(2026, 10, 20),
        capturedBy: 'EasySave',
        metadataDate: DateTime.utc(2026, 10, 20),
        sourceUrl: 'https://example.com/test',
        platform: 'web',
        sourceId: 'test',
      );
      
      final withXmp = writeWebpXmp(webp, xmp);
      
      // Extract VP8 chunk after XMP write
      final newVp8 = _extractChunk(withXmp, 'VP8 ');
      
      // VP8 bitstream must be identical
      expect(newVp8, originalVp8);
    });
  });
}

// Test fixtures

Uint8List _minimalJpeg() {
  return Uint8List.fromList([
    0xFF, 0xD8, // SOI
    0xFF, 0xE0, 0x00, 0x10, // APP0 length=16
    0x4A, 0x46, 0x49, 0x46, 0x00, // "JFIF\0"
    ...List.filled(9, 0), // APP0 padding
    0xFF, 0xC0, 0x00, 0x0B, // SOF0 length=11
    0x08, 0x00, 0x01, 0x00, 0x01, // 8-bit, 1x1 pixels
    0x01, 0x01, 0x11, 0x00, // 1 component
    0xFF, 0xDA, 0x00, 0x08, // SOS length=8
    0x01, 0x01, 0x00, 0x00, 0x3F, 0x00, // SOS header
    0xFF, 0xD9, // EOI
  ]);
}

Uint8List _minimalPng() {
  return Uint8List.fromList([
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
}

Uint8List _minimalWebpVp8() {
  // Minimal VP8 (lossy) WebP: 1x1 pixel
  return Uint8List.fromList([
    0x52, 0x49, 0x46, 0x46, // "RIFF"
    0x20, 0x00, 0x00, 0x00, // File size - 8
    0x57, 0x45, 0x42, 0x50, // "WEBP"
    0x56, 0x50, 0x38, 0x20, // "VP8 "
    0x14, 0x00, 0x00, 0x00, // Chunk size = 20
    // VP8 bitstream (20 bytes)
    0x00, 0x00, 0x00, // Frame tag
    0x9D, 0x01, 0x2A, // Start code
    0x01, 0x00, 0x01, 0x00, // Width=1, Height=1
    ...List.filled(10, 0), // Minimal frame data
  ]);
}

Uint8List _minimalWebpVp8l() {
  // Minimal VP8L (lossless) WebP: 1x1 pixel
  return Uint8List.fromList([
    0x52, 0x49, 0x46, 0x46, // "RIFF"
    0x18, 0x00, 0x00, 0x00, // File size - 8
    0x57, 0x45, 0x42, 0x50, // "WEBP"
    0x56, 0x50, 0x38, 0x4C, // "VP8L"
    0x0C, 0x00, 0x00, 0x00, // Chunk size = 12
    // VP8L bitstream
    0x2F, // Signature
    0x00, 0x00, 0x00, 0x00, // Width=1, Height=1 (14 bits each)
    ...List.filled(7, 0), // Minimal lossless data
  ]);
}

Uint8List _minimalWebpExtended() {
  // Extended format with VP8X header
  return Uint8List.fromList([
    0x52, 0x49, 0x46, 0x46, // "RIFF"
    0x30, 0x00, 0x00, 0x00, // File size - 8
    0x57, 0x45, 0x42, 0x50, // "WEBP"
    0x56, 0x50, 0x38, 0x58, // "VP8X"
    0x0A, 0x00, 0x00, 0x00, // Chunk size = 10
    0x00, 0x00, 0x00, 0x00, // Flags
    0x00, 0x00, 0x00, // Canvas width - 1 (24-bit)
    0x00, 0x00, 0x00, // Canvas height - 1 (24-bit)
    0x56, 0x50, 0x38, 0x20, // "VP8 "
    0x14, 0x00, 0x00, 0x00, // Chunk size = 20
    0x00, 0x00, 0x00, // Frame tag
    0x9D, 0x01, 0x2A, // Start code
    0x01, 0x00, 0x01, 0x00, // Width=1, Height=1
    ...List.filled(10, 0), // Minimal frame data
  ]);
}

Uint8List? _extractChunk(Uint8List webp, String fourCC) {
  int offset = 12;
  while (offset + 8 <= webp.length) {
    final chunkFourCC = String.fromCharCodes(webp.sublist(offset, offset + 4));
    final chunkSize = webp[offset + 4] |
        (webp[offset + 5] << 8) |
        (webp[offset + 6] << 16) |
        (webp[offset + 7] << 24);
    
    if (chunkFourCC == fourCC) {
      return webp.sublist(offset + 8, offset + 8 + chunkSize);
    }
    
    offset += 8 + chunkSize;
    if (chunkSize % 2 == 1) offset++; // padding
  }
  
  return null;
}
