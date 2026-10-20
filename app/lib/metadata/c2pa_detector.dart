// Copyright 2026 EasySave. All rights reserved.
// C2PA content credentials detector for JPEG, PNG, and WebP.
// Detects C2PA signatures without fully parsing the manifest.

import 'dart:typed_data';

/// Result of C2PA detection scan.
enum C2paStatus {
  /// No C2PA signature found in the file.
  none,
  
  /// C2PA content credentials detected.
  detected,
}

/// Scans a file for C2PA content credentials.
/// Returns C2paStatus.detected if C2PA signature is found, C2paStatus.none otherwise.
C2paStatus detectC2pa(Uint8List bytes, String format) {
  switch (format.toUpperCase()) {
    case 'JPEG':
      return _detectC2paJpeg(bytes);
    case 'PNG':
      return _detectC2paPng(bytes);
    case 'WEBP':
      return _detectC2paWebp(bytes);
    default:
      return C2paStatus.none;
  }
}

/// Detect C2PA in JPEG by scanning for APP11 (0xFFEB) segment with JUMBF data.
/// C2PA manifests are typically stored in JUMBF boxes within APP11 segments.
C2paStatus _detectC2paJpeg(Uint8List bytes) {
  if (bytes.length < 2 || bytes[0] != 0xFF || bytes[1] != 0xD8) {
    return C2paStatus.none; // Not a valid JPEG
  }

  int offset = 2;

  while (offset < bytes.length - 1) {
    if (bytes[offset] != 0xFF) break;

    final marker = bytes[offset + 1];
    if (marker == 0xD9) break; // EOI

    offset += 2;
    
    // Standalone markers without length
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      continue;
    }

    if (offset + 2 > bytes.length) break;

    final segmentLength = (bytes[offset] << 8) | bytes[offset + 1];
    if (segmentLength < 2) break;

    // Check for APP11 (0xFFEB) which contains JUMBF for C2PA
    if (marker == 0xEB) {
      final segmentData = bytes.sublist(offset + 2, offset + segmentLength);
      if (_hasC2paJumbf(segmentData)) {
        return C2paStatus.detected;
      }
    }

    offset += segmentLength;
  }

  return C2paStatus.none;
}

/// Check if JUMBF data contains C2PA signature.
/// JUMBF boxes start with UUID and contain label information.
bool _hasC2paJumbf(Uint8List data) {
  // JUMBF box structure:
  // - UUID (16 bytes): unique identifier
  // - Label (null-terminated string): describes the box type
  // - Data...
  //
  // C2PA content credentials have UUID: 001c7d0c-8000-11ea-b60d-17b883a60f0d
  // or contain "c2pa" in the label

  // Check for C2PA UUID (big-endian UUID)
  // UUID: 001c7d0c-8000-11ea-b60d-17b883a60f0d
  const c2paUuid = [
    0x00, 0x1c, 0x7d, 0x0c, // uuid[0-3]
    0x80, 0x00,             // uuid[4-5]
    0x11, 0xea,             // uuid[6-7]
    0xb6, 0x0d,             // uuid[8-9]
    0x17, 0xb8, 0x83, 0xa6, 0x0f, 0x0d // uuid[10-15]
  ];

  // Check for C2PA UUID at the start
  if (data.length >= 16) {
    bool uuidMatch = true;
    for (int i = 0; i < 16; i++) {
      if (data[i] != c2paUuid[i]) {
        uuidMatch = false;
        break;
      }
    }
    if (uuidMatch) {
      return true;
    }
  }

  // Also check for "c2pa" label anywhere in the JUMBF data
  // The label is a null-terminated string after the UUID
  if (data.length > 16) {
    // Look for "c2pa" (case-insensitive) in the label area
    final labelArea = data.sublist(16);
    final labelString = String.fromCharCodes(labelArea).toLowerCase();
    if (labelString.contains('c2pa')) {
      return true;
    }
  }

  return false;
}

/// Detect C2PA in PNG by scanning for caBX chunk.
/// C2PA uses a proprietary chunk type 'caBX' in PNG files.
C2paStatus _detectC2paPng(Uint8List bytes) {
  // PNG signature is 8 bytes
  if (bytes.length < 8 ||
      bytes[0] != 0x89 || bytes[1] != 0x50 || bytes[2] != 0x4E || bytes[3] != 0x47 ||
      bytes[4] != 0x0D || bytes[5] != 0x0A || bytes[6] != 0x1A || bytes[7] != 0x0A) {
    return C2paStatus.none; // Not a valid PNG
  }

  int offset = 8; // Skip PNG signature

  while (offset + 12 <= bytes.length) {
    final length = (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
    final chunkType = String.fromCharCodes(bytes.sublist(offset + 4, offset + 8));

    if (chunkType == 'IEND') {
      break; // End of PNG
    }

    // Check for C2PA chunk types:
    // - 'caBX' (Adobe C2PA)
    // - 'c2Ch' (C2PA content hash)
    // - 'c2Sp' (C2PA assertion)
    if (chunkType == 'caBX' || chunkType == 'c2Ch' || chunkType == 'c2Sp') {
      return C2paStatus.detected;
    }

    offset += 12 + length; // chunk type (4) + length (4) + data + CRC (4)
  }

  return C2paStatus.none;
}

/// Detect C2PA in WebP by scanning RIFF chunks for 'C2PA' box.
/// C2PA content credentials in WebP are stored in a 'C2PA' RIFF box.
C2paStatus _detectC2paWebp(Uint8List bytes) {
  // RIFF header check
  if (bytes.length < 12 ||
      bytes[0] != 0x52 || bytes[1] != 0x49 || bytes[2] != 0x46 || bytes[3] != 0x46 || // 'RIFF'
      bytes[8] != 0x57 || bytes[9] != 0x45 || bytes[10] != 0x42 || bytes[11] != 0x50) { // 'WEBP'
    return C2paStatus.none; // Not a valid WebP
  }

  // Start scanning chunks after the RIFF header (offset 12)
  // Note: C2PA can appear as a top-level RIFF chunk (alongside WEBP)
  // or embedded within the WEBP container
  int offset = 12;

  while (offset + 8 <= bytes.length) {
    final fourCC = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final chunkSize = bytes[offset + 4] |
        (bytes[offset + 5] << 8) |
        (bytes[offset + 6] << 16) |
        (bytes[offset + 7] << 24);

    final dataEnd = offset + 8 + chunkSize;
    if (dataEnd > bytes.length) break;

    // Check for C2PA chunk
    if (fourCC == 'C2PA') {
      return C2paStatus.detected;
    }

    // Skip to next chunk
    offset = dataEnd;
    // Padding byte for odd-length chunks
    if (chunkSize % 2 == 1 && offset < bytes.length) {
      offset++;
    }
  }

  return C2paStatus.none;
}
