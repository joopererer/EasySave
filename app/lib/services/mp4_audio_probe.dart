// Audio-track check for downloaded MP4 files: reads only box headers and the
// moov box, never decodes media.

import 'dart:io';
import 'dart:typed_data';

/// The moov box is metadata only; anything larger is treated as unreadable.
const _maxMoovBytes = 64 * 1024 * 1024;

/// Whether the MP4 at [file] has a sound track (`trak/mdia/hdlr` of type
/// `soun`). Null when the file is not a readable MP4 or has no moov box.
Future<bool?> mp4HasAudioTrack(File file) async {
  RandomAccessFile? raf;
  try {
    raf = await file.open();
    final length = await raf.length();
    var offset = 0;
    while (offset + 8 <= length) {
      await raf.setPosition(offset);
      final header = await raf.read(16);
      final box = _boxHeader(header, 0, length - offset);
      if (box == null) return null;
      if (box.type == 'moov') {
        final bodyLength = box.size - box.headerLength;
        if (bodyLength > _maxMoovBytes) return null;
        await raf.setPosition(offset + box.headerLength);
        return moovHasSoundTrack(await raf.read(bodyLength));
      }
      offset += box.size;
    }
    return null;
  } catch (_) {
    return null;
  } finally {
    await raf?.close();
  }
}

/// Same check over an in-memory MP4.
bool? mp4BytesHaveAudioTrack(Uint8List bytes) {
  for (final box in _children(bytes, 0, bytes.length)) {
    if (box.type == 'moov') {
      return moovHasSoundTrack(
        Uint8List.sublistView(bytes, box.bodyStart, box.end),
      );
    }
  }
  return null;
}

/// True when any track's handler is `soun`, false when the moov box has
/// tracks but none of them is sound, null when it has no readable track.
bool? moovHasSoundTrack(Uint8List moovBody) {
  var tracks = 0;
  for (final trak in _children(moovBody, 0, moovBody.length)) {
    if (trak.type != 'trak') continue;
    tracks++;
    for (final mdia in _children(moovBody, trak.bodyStart, trak.end)) {
      if (mdia.type != 'mdia') continue;
      for (final hdlr in _children(moovBody, mdia.bodyStart, mdia.end)) {
        // hdlr body: version/flags (4), pre_defined (4), handler_type (4).
        if (hdlr.type == 'hdlr' &&
            hdlr.end - hdlr.bodyStart >= 12 &&
            _fourCc(moovBody, hdlr.bodyStart + 8) == 'soun') {
          return true;
        }
      }
    }
  }
  return tracks == 0 ? null : false;
}

class _Box {
  const _Box(this.type, this.start, this.size, this.headerLength);

  final String type;
  final int start;
  final int size;
  final int headerLength;

  int get bodyStart => start + headerLength;
  int get end => start + size;
}

/// Header of a box starting at [offset] with [available] bytes left in its
/// parent. Handles 64-bit sizes and the "extends to the end" size 0.
_Box? _boxHeader(Uint8List bytes, int offset, int available) {
  if (bytes.length - offset < 8 || available < 8) return null;
  final data = ByteData.sublistView(bytes);
  var size = data.getUint32(offset);
  final type = _fourCc(bytes, offset + 4);
  var headerLength = 8;
  if (size == 1) {
    if (bytes.length - offset < 16) return null;
    size = data.getUint64(offset + 8);
    headerLength = 16;
  } else if (size == 0) {
    size = available;
  }
  if (size < headerLength || size > available) return null;
  return _Box(type, offset, size, headerLength);
}

Iterable<_Box> _children(Uint8List bytes, int start, int end) sync* {
  var offset = start;
  while (offset + 8 <= end) {
    final box = _boxHeader(bytes, offset, end - offset);
    if (box == null) return;
    yield _Box(box.type, offset, box.size, box.headerLength);
    offset += box.size;
  }
}

String _fourCc(Uint8List bytes, int offset) =>
    String.fromCharCodes(bytes.sublist(offset, offset + 4));
