// Copyright 2026 EasySave. All rights reserved.
// JPEG XMP reader/writer - pure Dart byte manipulation.
// APP1 segment format: 0xFFE1 [length:2] header payload
// The header tells the payload kind apart: XMP starts with
// "http://ns.adobe.com/xap/1.0/\0", EXIF starts with "Exif\0\0".
// Headers are compared as raw bytes; payloads are never UTF-8 decoded
// unless the header says they are XMP.

import 'dart:convert';
import 'dart:typed_data';

import 'xmp_model.dart';
import 'xmp_core.dart' show parseXmpXml, buildXmpXml, mergeXmp;

/// "http://ns.adobe.com/xap/1.0/\0" as raw bytes (29 bytes, pure ASCII).
final Uint8List _xmpHeader = Uint8List.fromList(
  'http://ns.adobe.com/xap/1.0/\x00'.codeUnits,
);

/// "Exif\0\0" as raw bytes (6 bytes).
final Uint8List _exifHeader = Uint8List.fromList(
  [0x45, 0x78, 0x69, 0x66, 0x00, 0x00],
);

enum _App1Kind { xmp, exif, other }

class _Segment {
  const _Segment(this.marker, this.start, this.end, this.kind);

  final int marker;

  /// Offset of the 0xFF marker byte.
  final int start;

  /// Offset just past the last byte of the segment.
  final int end;

  /// Only meaningful for APP1 (0xE1); `other` for everything else.
  final _App1Kind kind;
}

class _Scan {
  const _Scan(this.segments, this.restStart);

  /// Header segments between SOI and the first SOS/EOI/unparsable byte.
  final List<_Segment> segments;

  /// Offset where the untouched remainder (SOS, scan data, EOI) begins.
  final int restStart;
}

bool _startsWith(Uint8List bytes, int start, int end, Uint8List prefix) {
  if (end - start < prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (bytes[start + i] != prefix[i]) return false;
  }
  return true;
}

/// Scans JPEG header segments (between SOI and first SOS/EOI).
/// Returns [segments] (APP0, APP1, ..., COM, etc.) with their kind,
/// and [restStart] where the untouched remainder begins.
_Scan _scanSegments(Uint8List bytes) {
  if (bytes.length < 2 || bytes[0] != 0xFF || bytes[1] != 0xD8) {
    throw FormatException('Not a JPEG file');
  }

  final segments = <_Segment>[];
  int offset = 2;

  while (offset < bytes.length - 1) {
    if (bytes[offset] != 0xFF) break;

    final marker = bytes[offset + 1];

    // Scan data or end-of-image; stop parsing headers.
    if (marker == 0xD9 || marker == 0xDA) break;

    // Standalone marker; no length field, no payload.
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      segments.add(_Segment(marker, offset, offset + 2, _App1Kind.other));
      offset += 2;
      continue;
    }

    // Segment with length; advance past marker and read length.
    if (offset + 4 > bytes.length) break;

    final segmentStart = offset;
    offset += 2;
    final segmentLength = (bytes[offset] << 8) | bytes[offset + 1];
    if (segmentLength < 2) break;

    offset += segmentLength;
    if (offset > bytes.length) break;

    // Determine APP1 kind (XMP or EXIF).
    _App1Kind kind = _App1Kind.other;
    if (marker == 0xE1) {
      final payloadStart = segmentStart + 4;
      if (_startsWith(bytes, payloadStart, offset, _xmpHeader)) {
        kind = _App1Kind.xmp;
      } else if (_startsWith(bytes, payloadStart, offset, _exifHeader)) {
        kind = _App1Kind.exif;
      }
    }

    segments.add(_Segment(marker, segmentStart, offset, kind));
  }

  return _Scan(segments, offset);
}

/// Reads XMP from JPEG APP1 segment.
/// Returns null if no XMP found (including valid EXIF or other APP1 segments).
XmpProvenance? readJpegXmp(Uint8List bytes) {
  final scan = _scanSegments(bytes);

  for (final segment in scan.segments) {
    if (segment.marker == 0xE1 && segment.kind == _App1Kind.xmp) {
      // XMP APP1: skip header, decode payload.
      final payloadStart = segment.start + 4 + _xmpHeader.length;
      final xmpPayload = utf8.decode(bytes.sublist(payloadStart, segment.end));
      return parseXmpXml(xmpPayload);
    }
  }

  return null;
}

/// Writes XMP into JPEG APP1 segment.
/// Replaces existing XMP APP1, or inserts after first APPn, or after SOI.
/// Preserves EXIF and all other segments byte-for-byte.
Uint8List writeJpegXmp(Uint8List bytes, XmpProvenance xmp) {
  if (bytes.length < 2 || bytes[0] != 0xFF || bytes[1] != 0xD8) {
    throw FormatException('Not a JPEG file');
  }

  final scan = _scanSegments(bytes);

  // Build new XMP APP1 segment data.
  final existing = readJpegXmp(bytes);
  final merged = mergeXmp(existing, xmp);
  final xmpPayload = buildXmpXml(merged);
  final xmpSegmentPayload = Uint8List.fromList([
    ..._xmpHeader,
    ...utf8.encode(xmpPayload),
  ]);
  final newSegmentLength = 2 + xmpSegmentPayload.length;

  if (newSegmentLength > 65535) {
    throw ArgumentError('XMP payload too large for single APP1 segment');
  }

  final builder = BytesBuilder();
  builder.add([0xFF, 0xD8]); // SOI

  bool xmpWritten = false;
  int xmpInsertAfterIndex = -1; // After which segment index to insert new XMP?

  // Copy existing segments, replacing any existing XMP.
  for (int i = 0; i < scan.segments.length; i++) {
    final segment = scan.segments[i];

    if (segment.marker == 0xE1 && segment.kind == _App1Kind.xmp) {
      // Replace this XMP segment with the new one.
      builder.add([0xFF, 0xE1]);
      builder.add([newSegmentLength >> 8, newSegmentLength & 0xFF]);
      builder.add(xmpSegmentPayload);
      xmpWritten = true;
      continue;
    }

    // Copy the segment as-is (including EXIF).
    builder.add(bytes.sublist(segment.start, segment.end));

    // Mark where to insert new XMP: after the first APP (non-APP0/APP1 for now).
    if (!xmpWritten && xmpInsertAfterIndex < 0 &&
        segment.marker >= 0xE0 && segment.marker <= 0xEF) {
      xmpInsertAfterIndex = i;
    }
  }

  // If we haven't written XMP yet:
  if (!xmpWritten) {
    if (xmpInsertAfterIndex >= 0) {
      // Should have inserted after the APPn segment. Re-scan and insert.
      // For simplicity, re-build from scratch.
      final builder2 = BytesBuilder();
      builder2.add([0xFF, 0xD8]); // SOI

      for (int i = 0; i < scan.segments.length; i++) {
        final segment = scan.segments[i];
        builder2.add(bytes.sublist(segment.start, segment.end));

        if (i == xmpInsertAfterIndex) {
          builder2.add([0xFF, 0xE1]);
          builder2.add([newSegmentLength >> 8, newSegmentLength & 0xFF]);
          builder2.add(xmpSegmentPayload);
        }
      }

      builder2.add(bytes.sublist(scan.restStart)); // Rest (scan data, EOI)
      return builder2.toBytes();
    } else {
      // No APPn found; insert right after SOI.
      builder.add([0xFF, 0xE1]);
      builder.add([newSegmentLength >> 8, newSegmentLength & 0xFF]);
      builder.add(xmpSegmentPayload);
    }
  }

  // Append untouched remainder (scan data, EOI, etc.).
  builder.add(bytes.sublist(scan.restStart));

  return builder.toBytes();
}
