// Copyright 2026 EasySave. All rights reserved.
// JPEG XMP reader/writer - pure Dart byte manipulation.
// APP1 segment format: 0xFFE1 [length:2] "http://ns.adobe.com/xap/1.0/\0" [XMP]

import 'dart:convert';
import 'dart:typed_data';

import 'xmp_model.dart';
import 'xmp_core.dart' show parseXmpXml, buildXmpXml, mergeXmp;

const _xmpHeader = 'http://ns.adobe.com/xap/1.0/\x00';
const _xmpHeaderBytes = _xmpHeader.length; // 29

/// Reads XMP from JPEG APP1 segment.
/// Returns null if no XMP found.
XmpProvenance? readJpegXmp(Uint8List bytes) {
  if (bytes.length < 2 || bytes[0] != 0xFF || bytes[1] != 0xD8) {
    throw FormatException('Not a JPEG file');
  }

  int offset = 2;
  while (offset < bytes.length - 1) {
    if (bytes[offset] != 0xFF) break;

    final marker = bytes[offset + 1];
    if (marker == 0xD9) break; // EOI

    offset += 2;
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      // Standalone markers without length
      continue;
    }

    if (offset + 2 > bytes.length) break;

    final segmentLength = (bytes[offset] << 8) | bytes[offset + 1];
    if (segmentLength < 2) break;

    if (marker == 0xE1 && offset + 2 + _xmpHeaderBytes <= bytes.length) {
      // APP1 segment
      final headerStart = offset + 2;
      final headerEnd = headerStart + _xmpHeaderBytes;
      
      // Check if we have enough space for header
      if (headerEnd <= offset + segmentLength) {
        final header = utf8.decode(bytes.sublist(headerStart, headerEnd));

        if (header == _xmpHeader) {
          // Found XMP segment
          final xmpStart = headerEnd;
          final xmpEnd = offset + segmentLength;
          final xmpPayload = utf8.decode(bytes.sublist(xmpStart, xmpEnd));
          return parseXmpXml(xmpPayload);
        }
      }
    }

    offset += segmentLength;
  }

  return null;
}

/// Writes XMP into JPEG APP1 segment.
/// Returns new JPEG bytes with XMP written.
/// Replaces existing XMP APP1 if present, otherwise inserts after SOI.
/// Preserves existing assetId and foreign fields when replacing.
Uint8List writeJpegXmp(Uint8List bytes, XmpProvenance xmp) {
  if (bytes.length < 2 || bytes[0] != 0xFF || bytes[1] != 0xD8) {
    throw FormatException('Not a JPEG file');
  }

  // Check if existing XMP exists and merge with it
  final existing = readJpegXmp(bytes);
  final merged = mergeXmp(existing, xmp);

  final xmpPayload = buildXmpXml(merged);
  final xmpBytes = utf8.encode(_xmpHeader + xmpPayload);
  final newSegmentLength = 2 + xmpBytes.length;
  
  if (newSegmentLength > 65535) {
    throw ArgumentError('XMP payload too large for single APP1 segment');
  }

  final builder = BytesBuilder();
  int offset = 2;
  bool xmpWritten = false;

  // SOI
  builder.add([0xFF, 0xD8]);

  while (offset < bytes.length - 1) {
    if (bytes[offset] != 0xFF) break;

    final marker = bytes[offset + 1];
    if (marker == 0xD9) break; // EOI

    offset += 2;
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      // Standalone markers - copy as-is
      builder.add([0xFF, marker]);
      continue;
    }

    if (offset + 2 > bytes.length) break;

    final segmentLength = (bytes[offset] << 8) | bytes[offset + 1];
    if (segmentLength < 2) break;

    if (marker == 0xE1 && offset + 2 + _xmpHeaderBytes <= bytes.length) {
      // Check if this is XMP APP1
      final headerStart = offset + 2;
      final headerEnd = headerStart + _xmpHeaderBytes;
      
      if (headerEnd <= offset + segmentLength) {
        final header = utf8.decode(bytes.sublist(headerStart, headerEnd));

        if (header == _xmpHeader) {
          // Replace existing XMP
          builder.add([0xFF, 0xE1]);
          builder.add([newSegmentLength >> 8, newSegmentLength & 0xFF]);
          builder.add(xmpBytes);
          xmpWritten = true;
          offset += segmentLength;
          continue;
        }
      }
    }

    // Copy segment as-is
    builder.add([0xFF, marker]);
    builder.add(bytes.sublist(offset, offset + segmentLength));
    offset += segmentLength;

    // Insert XMP after first non-XMP APP segment if not yet written
    if (!xmpWritten && (marker >= 0xE0 && marker <= 0xEF)) {
      builder.add([0xFF, 0xE1]);
      builder.add([newSegmentLength >> 8, newSegmentLength & 0xFF]);
      builder.add(xmpBytes);
      xmpWritten = true;
    }
  }

  // If no XMP written yet, insert after SOI (offset should be at first scan or EOI)
  if (!xmpWritten) {
    final temp = builder.toBytes();
    builder.clear();
    builder.add([0xFF, 0xD8]); // SOI
    builder.add([0xFF, 0xE1]); // APP1
    builder.add([newSegmentLength >> 8, newSegmentLength & 0xFF]);
    builder.add(xmpBytes);
    builder.add(temp.sublist(2)); // Rest after SOI
  }

  // Copy remaining bytes (scan data + EOI)
  if (offset < bytes.length) {
    builder.add(bytes.sublist(offset));
  }

  return builder.toBytes();
}
