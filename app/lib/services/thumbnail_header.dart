import 'dart:typed_data';

/// Container and dimension checks only; never allocates decoded pixels.
void validateThumbnailHeader(Uint8List bytes) {
  Never invalid() => throw const FormatException('THUMBNAIL_HEADER');
  if (bytes.length < 12) invalid();
  final data = ByteData.sublistView(bytes);
  bool tag(int offset, String value) =>
      offset + value.length <= bytes.length &&
      List.generate(
        value.length,
        (i) => bytes[offset + i] == value.codeUnitAt(i),
      ).every((v) => v);
  void dimensions(int w, int h) {
    if (w <= 0 || h <= 0) invalid();
  }

  if (bytes[0] == 255 && bytes[1] == 216) {
    if (bytes[bytes.length - 2] != 255 || bytes.last != 217) invalid();
    var offset = 2;
    while (offset + 4 <= bytes.length) {
      if (bytes[offset++] != 255) invalid();
      while (offset < bytes.length && bytes[offset] == 255) {
        offset++;
      }
      if (offset >= bytes.length) invalid();
      final marker = bytes[offset++];
      if (marker == 0xda || marker == 0xd9) break;
      if (marker == 1 || (marker >= 0xd0 && marker <= 0xd7)) continue;
      if (offset + 2 > bytes.length) invalid();
      final length = data.getUint16(offset);
      if (length < 2 || offset + length > bytes.length) invalid();
      if ([
        0xc0,
        0xc1,
        0xc2,
        0xc3,
        0xc5,
        0xc6,
        0xc7,
        0xc9,
        0xca,
        0xcb,
        0xcd,
        0xce,
        0xcf,
      ].contains(marker)) {
        if (length < 8) invalid();
        dimensions(data.getUint16(offset + 5), data.getUint16(offset + 3));
        return;
      }
      offset += length;
    }
    invalid();
  }
  if (tag(0, '\u0089PNG\r\n\u001a\n')) {
    if (bytes.length < 45 ||
        !tag(12, 'IHDR') ||
        data.getUint32(8) != 13 ||
        data.getUint32(bytes.length - 12) != 0 ||
        !tag(bytes.length - 8, 'IEND') ||
        data.getUint32(bytes.length - 4) != 0xae426082)
      invalid();
    dimensions(data.getUint32(16), data.getUint32(20));
    var offset = 8;
    while (offset < bytes.length) {
      if (offset + 12 > bytes.length) invalid();
      offset += data.getUint32(offset) + 12;
      if (offset > bytes.length) invalid();
    }
    return;
  }
  if (tag(0, 'RIFF') && tag(8, 'WEBP')) {
    if (data.getUint32(4, Endian.little) + 8 != bytes.length) invalid();
    var offset = 12;
    var found = false;
    int u24(int p) => bytes[p] | bytes[p + 1] << 8 | bytes[p + 2] << 16;
    while (offset + 8 <= bytes.length) {
      final size = data.getUint32(offset + 4, Endian.little);
      final p = offset + 8;
      if (p + size > bytes.length) invalid();
      if (tag(offset, 'VP8X')) {
        if (size != 10) invalid();
        dimensions(u24(p + 4) + 1, u24(p + 7) + 1);
        found = true;
      } else if (tag(offset, 'VP8L')) {
        if (size < 5 || bytes[p] != 0x2f) invalid();
        final bits = data.getUint32(p + 1, Endian.little);
        dimensions((bits & 0x3fff) + 1, ((bits >> 14) & 0x3fff) + 1);
        found = true;
      } else if (tag(offset, 'VP8 ')) {
        if (size < 10 || !tag(p + 3, '\u009d\u0001\u002a')) invalid();
        dimensions(
          data.getUint16(p + 6, Endian.little) & 0x3fff,
          data.getUint16(p + 8, Endian.little) & 0x3fff,
        );
        found = true;
      }
      offset = p + size + (size & 1);
    }
    if (!found || offset != bytes.length) invalid();
    return;
  }
  invalid();
}
