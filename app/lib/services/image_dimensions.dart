// Pixel size of a downloaded image from its header: JPEG SOF, PNG IHDR and
// WebP VP8 / VP8L / VP8X. Never decodes the image.

import 'dart:io';
import 'dart:typed_data';

typedef ImageSize = ({int width, int height});

/// Header size of the image at [path], or null for other formats or damage.
Future<ImageSize?> readImageSize(String path) async {
  RandomAccessFile? raf;
  try {
    raf = await File(path).open();
    final length = await raf.length();
    final head = await raf.read(32);
    if (head.length < 12) return null;
    // PNG: signature, then the IHDR chunk.
    if (head[0] == 0x89 && head[1] == 0x50 && head[2] == 0x4E && head[3] == 0x47) {
      if (head.length < 24) return null;
      final data = ByteData.sublistView(head);
      return (width: data.getUint32(16), height: data.getUint32(20));
    }
    // WebP: RIFF....WEBP and the first chunk.
    if (String.fromCharCodes(head.sublist(0, 4)) == 'RIFF' &&
        String.fromCharCodes(head.sublist(8, 12)) == 'WEBP' &&
        head.length >= 30) {
      final chunk = String.fromCharCodes(head.sublist(12, 16));
      if (chunk == 'VP8X') {
        int le24(int o) => head[o] | head[o + 1] << 8 | head[o + 2] << 16;
        return (width: 1 + le24(24), height: 1 + le24(27));
      }
      if (chunk == 'VP8L') {
        final b0 = head[21], b1 = head[22], b2 = head[23], b3 = head[24];
        return (
          width: 1 + (((b1 & 0x3F) << 8) | b0),
          height: 1 + (((b3 & 0x0F) << 10) | (b2 << 2) | ((b1 & 0xC0) >> 6)),
        );
      }
      if (chunk == 'VP8 ') {
        final data = ByteData.sublistView(head);
        return (
          width: data.getUint16(26, Endian.little) & 0x3FFF,
          height: data.getUint16(28, Endian.little) & 0x3FFF,
        );
      }
      return null;
    }
    // JPEG: walk segments to the first start-of-frame marker.
    if (head[0] == 0xFF && head[1] == 0xD8) {
      var offset = 2;
      while (offset + 4 <= length) {
        await raf.setPosition(offset);
        final marker = await raf.read(4);
        if (marker.length < 4 || marker[0] != 0xFF) return null;
        final code = marker[1];
        if (code == 0xFF) {
          offset += 1;
          continue;
        }
        if (code == 0xD8 || code == 0x01 || (code >= 0xD0 && code <= 0xD7)) {
          offset += 2;
          continue;
        }
        final segment = marker[2] << 8 | marker[3];
        if (segment < 2) return null;
        final isFrame = code >= 0xC0 && code <= 0xCF &&
            code != 0xC4 && code != 0xC8 && code != 0xCC;
        if (isFrame) {
          final frame = await raf.read(5);
          if (frame.length < 5) return null;
          return (width: frame[3] << 8 | frame[4], height: frame[1] << 8 | frame[2]);
        }
        if (code == 0xDA || code == 0xD9) return null;
        offset += 2 + segment;
      }
    }
    return null;
  } catch (_) {
    return null;
  } finally {
    await raf?.close();
  }
}

/// Whether [actual] is clearly smaller than the size the platform declared:
/// its long side is below 80 % of the declared long side. Orientation is
/// ignored (a rotated file swaps width and height).
bool isLowResolution(int expectedWidth, int expectedHeight, int width, int height) {
  final expectedLong = expectedWidth > expectedHeight ? expectedWidth : expectedHeight;
  final actualLong = width > height ? width : height;
  return expectedLong > 0 && actualLong < expectedLong * 0.8;
}
