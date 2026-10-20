// Copyright 2026 EasySave. All rights reserved.
// WebP XMP reader/writer - pure Dart byte manipulation.
// RIFF XMP chunk format: FourCC "XMP " [payload]

import 'dart:convert';
import 'dart:typed_data';

import 'xmp_model.dart';
import 'xmp_jpeg.dart' show parseXmpXml, buildXmpXml;

/// Reads XMP from WebP RIFF XMP chunk.
/// Returns null if no XMP found.
XmpProvenance? readWebpXmp(Uint8List bytes) {
  if (bytes.length < 12 ||
      bytes[0] != 0x52 || // 'R'
      bytes[1] != 0x49 || // 'I'
      bytes[2] != 0x46 || // 'F'
      bytes[3] != 0x46 || // 'F'
      bytes[8] != 0x57 || // 'W'
      bytes[9] != 0x45 || // 'E'
      bytes[10] != 0x42 || // 'B'
      bytes[11] != 0x50) {
    throw FormatException('Not a WebP file');
  }

  int offset = 12;
  while (offset + 8 <= bytes.length) {
    final fourCC = utf8.decode(bytes.sublist(offset, offset + 4));
    final chunkSize = _readU32(bytes, offset + 4);
    final dataStart = offset + 8;
    final dataEnd = dataStart + chunkSize;

    if (dataEnd > bytes.length) break;

    if (fourCC == 'XMP ') {
      final xmpPayload = utf8.decode(bytes.sublist(dataStart, dataEnd));
      return parseXmpXml(xmpPayload);
    }

    offset = dataEnd;
    // RIFF chunks must be 2-byte aligned
    if (chunkSize % 2 == 1) offset++;
  }

  return null;
}

/// Writes XMP into WebP RIFF XMP chunk.
/// Returns new WebP bytes with XMP written.
/// Replaces existing XMP chunk if present, otherwise appends.
/// Simple format (VP8/VP8L) is upgraded to VP8X with XMP flag.
/// Preserves existing assetId and foreign fields when replacing.
Uint8List writeWebpXmp(Uint8List bytes, XmpProvenance xmp) {
  if (bytes.length < 12 ||
      bytes[0] != 0x52 ||
      bytes[1] != 0x49 ||
      bytes[2] != 0x46 ||
      bytes[3] != 0x46 ||
      bytes[8] != 0x57 ||
      bytes[9] != 0x45 ||
      bytes[10] != 0x42 ||
      bytes[11] != 0x50) {
    throw FormatException('Not a WebP file');
  }

  // Check if existing XMP exists and merge with it
  final existing = readWebpXmp(bytes);
  final merged = existing != null ? _mergeXmp(existing, xmp) : xmp;

  final xmpPayload = buildXmpXml(merged);
  final xmpBytes = utf8.encode(xmpPayload);

  // Check format: extended (VP8X) or simple (VP8/VP8L)
  if (bytes.length >= 16) {
    final firstChunk = utf8.decode(bytes.sublist(12, 16));
    
    if (firstChunk == 'VP8X') {
      return _writeExtended(bytes, xmpBytes);
    } else if (firstChunk == 'VP8 ' || firstChunk == 'VP8L') {
      return _upgradeToExtended(bytes, xmpBytes, firstChunk);
    }
  }

  throw FormatException('Unknown WebP format');
}

/// Write XMP to extended format WebP (already has VP8X).
Uint8List _writeExtended(Uint8List bytes, List<int> xmpBytes) {
  final builder = BytesBuilder();
  bool xmpWritten = false;
  int offset = 12;

  // Copy RIFF header (12 bytes) - will update size at end
  builder.add(bytes.sublist(0, 12));

  while (offset + 8 <= bytes.length) {
    final fourCC = utf8.decode(bytes.sublist(offset, offset + 4));
    final chunkSize = _readU32(bytes, offset + 4);
    final dataStart = offset + 8;
    final dataEnd = dataStart + chunkSize;

    if (dataEnd > bytes.length) break;

    if (fourCC == 'VP8X') {
      // Update XMP flag (bit 2) in VP8X flags byte
      builder.add(utf8.encode('VP8X'));
      builder.add(_u32Bytes(chunkSize));
      
      final vp8xData = Uint8List.fromList(bytes.sublist(dataStart, dataEnd));
      vp8xData[0] |= 0x04; // Set XMP flag (bit 2)
      builder.add(vp8xData);
      
      if (chunkSize % 2 == 1) builder.add([0]); // padding
    } else if (fourCC == 'XMP ') {
      // Replace existing XMP
      builder.add(utf8.encode('XMP '));
      builder.add(_u32Bytes(xmpBytes.length));
      builder.add(xmpBytes);
      if (xmpBytes.length % 2 == 1) builder.add([0]); // padding
      xmpWritten = true;
    } else {
      // Copy chunk as-is
      final chunkEnd = dataEnd + (chunkSize % 2 == 1 ? 1 : 0);
      builder.add(bytes.sublist(offset, chunkEnd));
    }

    offset = dataEnd;
    if (chunkSize % 2 == 1) offset++; // skip padding
  }

  // Append XMP if not written
  if (!xmpWritten) {
    builder.add(utf8.encode('XMP '));
    builder.add(_u32Bytes(xmpBytes.length));
    builder.add(xmpBytes);
    if (xmpBytes.length % 2 == 1) builder.add([0]); // padding
  }

  // Update RIFF file size (4 bytes at offset 4)
  final result = builder.toBytes();
  final fileSize = result.length - 8;
  result[4] = fileSize & 0xFF;
  result[5] = (fileSize >> 8) & 0xFF;
  result[6] = (fileSize >> 16) & 0xFF;
  result[7] = (fileSize >> 24) & 0xFF;

  return result;
}

/// Upgrade simple format (VP8/VP8L) to extended (VP8X) and add XMP.
Uint8List _upgradeToExtended(Uint8List bytes, List<int> xmpBytes, String format) {
  // Read image dimensions from bitstream
  final dims = _readDimensions(bytes, format);
  
  final builder = BytesBuilder();
  
  // RIFF header (will update size at end)
  builder.add(bytes.sublist(0, 8));
  builder.add(utf8.encode('WEBP'));

  // VP8X chunk
  builder.add(utf8.encode('VP8X'));
  builder.add(_u32Bytes(10)); // VP8X data size is always 10
  builder.add([0x04, 0, 0, 0]); // flags: XMP bit set (bit 2)
  builder.add(_u24Bytes(dims.width - 1)); // Canvas width - 1
  builder.add(_u24Bytes(dims.height - 1)); // Canvas height - 1

  // Copy original VP8/VP8L chunk
  int offset = 12;
  while (offset + 8 <= bytes.length) {
    final chunkSize = _readU32(bytes, offset + 4);
    final dataEnd = offset + 8 + chunkSize;
    
    if (dataEnd > bytes.length) break;
    
    final chunkEnd = dataEnd + (chunkSize % 2 == 1 ? 1 : 0);
    builder.add(bytes.sublist(offset, chunkEnd));
    
    offset = chunkEnd;
  }

  // Append XMP chunk
  builder.add(utf8.encode('XMP '));
  builder.add(_u32Bytes(xmpBytes.length));
  builder.add(xmpBytes);
  if (xmpBytes.length % 2 == 1) builder.add([0]); // padding

  // Update RIFF file size
  final result = builder.toBytes();
  final fileSize = result.length - 8;
  result[4] = fileSize & 0xFF;
  result[5] = (fileSize >> 8) & 0xFF;
  result[6] = (fileSize >> 16) & 0xFF;
  result[7] = (fileSize >> 24) & 0xFF;

  return result;
}

/// Read image dimensions from VP8/VP8L bitstream.
_Dimensions _readDimensions(Uint8List bytes, String format) {
  int offset = 12;
  
  while (offset + 8 <= bytes.length) {
    final fourCC = utf8.decode(bytes.sublist(offset, offset + 4));
    final chunkSize = _readU32(bytes, offset + 4);
    final dataStart = offset + 8;
    final dataEnd = dataStart + chunkSize;
    
    if (dataEnd > bytes.length) break;
    
    if (fourCC == format) {
      if (format == 'VP8 ') {
        return _readVp8Dimensions(bytes, dataStart);
      } else {
        return _readVp8lDimensions(bytes, dataStart);
      }
    }
    
    offset = dataEnd;
    if (chunkSize % 2 == 1) offset++; // padding
  }
  
  throw FormatException('Could not find $format chunk');
}

/// Read VP8 (lossy) dimensions from bitstream.
_Dimensions _readVp8Dimensions(Uint8List bytes, int start) {
  // Skip frame tag (3 bytes) and start code (3 bytes)
  if (start + 10 > bytes.length) {
    throw FormatException('VP8 chunk too short');
  }
  
  final offset = start + 6;
  final width = bytes[offset] | ((bytes[offset + 1] & 0x3F) << 8);
  final height = bytes[offset + 2] | ((bytes[offset + 3] & 0x3F) << 8);
  
  return _Dimensions(width, height);
}

/// Read VP8L (lossless) dimensions from bitstream.
_Dimensions _readVp8lDimensions(Uint8List bytes, int start) {
  // Signature (1 byte) + 14-bit width + 14-bit height
  if (start + 5 > bytes.length) {
    throw FormatException('VP8L chunk too short');
  }
  
  if (bytes[start] != 0x2F) {
    throw FormatException('Invalid VP8L signature');
  }
  
  // Read 28 bits (14+14) packed across 4 bytes
  final bits = (bytes[start + 1]) |
      (bytes[start + 2] << 8) |
      (bytes[start + 3] << 16) |
      (bytes[start + 4] << 24);
  
  final width = (bits & 0x3FFF) + 1;
  final height = ((bits >> 14) & 0x3FFF) + 1;
  
  return _Dimensions(width, height);
}

int _readU32(Uint8List bytes, int offset) {
  return bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);
}

List<int> _u32Bytes(int value) {
  return [
    value & 0xFF,
    (value >> 8) & 0xFF,
    (value >> 16) & 0xFF,
    (value >> 24) & 0xFF,
  ];
}

List<int> _u24Bytes(int value) {
  return [
    value & 0xFF,
    (value >> 8) & 0xFF,
    (value >> 16) & 0xFF,
  ];
}

class _Dimensions {
  final int width;
  final int height;
  
  _Dimensions(this.width, this.height);
}

/// Merge new XMP with existing, preserving assetId and foreign fields.
XmpProvenance _mergeXmp(XmpProvenance existing, XmpProvenance newXmp) {
  // Preserve existing assetId
  final assetId = existing.assetId;
  
  // Merge otherFields: keep existing foreign fields
  final mergedOtherFields = Map<String, String>.from(existing.otherFields);
  newXmp.otherFields.forEach((key, value) {
    if (!mergedOtherFields.containsKey(key)) {
      mergedOtherFields[key] = value;
    }
  });
  
  return XmpProvenance(
    schema: newXmp.schema,
    assetId: assetId,
    capturedAt: newXmp.capturedAt,
    capturedBy: newXmp.capturedBy,
    metadataDate: newXmp.metadataDate,
    sourceUrl: newXmp.sourceUrl,
    platform: newXmp.platform,
    sourceId: newXmp.sourceId,
    itemIndex: newXmp.itemIndex,
    itemCount: newXmp.itemCount,
    authorId: newXmp.authorId,
    publishedAt: newXmp.publishedAt,
    title: newXmp.title,
    creators: newXmp.creators,
    description: newXmp.description,
    credit: newXmp.credit,
    otherFields: mergedOtherFields,
  );
}
