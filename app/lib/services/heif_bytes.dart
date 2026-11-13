// What a HEIC/HEIF header says about itself, decided from its own bytes.
//
// Android 12's platform HEIF decoder rejects the HEIC files an iPhone writes
// when they carry an alpha auxiliary image (`urn:mpeg:hevc:2015:auxid:1` or
// `urn:mpeg:mpegB:cicp:systems:auxiliary:alpha`). Asking the system decoder
// whether it can show such a file is what stalled the history page in build 46:
// the decode never returned, the watchdog gave up on it, and the abandoned
// native decode kept the shared channel busy for every thumbnail behind it.
//
// So the format question is answered from the container structure instead —
// `ftyp`, `meta`/`iinf`, `meta`/`iref`, `meta`/`iprp`/`ipco`/`auxC`, with the
// `ipma` associations — by reading a bounded prefix of the file. No decoder is
// involved, nothing can hang, and the same parser serves a downloaded temp file
// and an album file read through MediaStore.
//
// Only fixed tokens leave this file (a brand, an alpha URN kind, a verdict), so
// a log line can never carry a path, a filename or a file size.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

/// HEIF brands that name a HEVC-encoded still image.
const Set<String> kHeifStillBrands = {
  'heic', 'heix', 'hevc', 'hevx', 'heim', 'heis', 'hevm', 'hevs',
  'mif1', 'msf1', 'mif2',
};

/// The `auxC` URNs that declare an alpha auxiliary image.
const String kAlphaAuxUrnHevc = 'urn:mpeg:hevc:2015:auxid:1';
const String kAlphaAuxUrnCicp = 'urn:mpeg:mpegB:cicp:systems:auxiliary:alpha';

/// Most bytes one decision may read, in total, whatever the file size is.
const int kHeifHeadBytes = 256 * 1024;

/// Most bytes of one `meta` box this build reads when the head did not hold it
/// whole. Everything the parser walks (`iinf`, `iref`, `iprp`) comes before the
/// item data inside `meta`, so this bound is generous.
const int kHeifMetaBytes = 128 * 1024;

/// Android SDK levels whose platform HEIF decoder rejects an alpha HEIC.
///
/// 31 is Android 12, reproduced on the reference device. Add a level here only
/// after the same failure was reproduced on a device of that level: a level
/// that is not listed keeps the old behaviour instead of rejecting files the
/// device may well show.
const Set<int> kHeicAlphaUnsupportedSdk = {31};

enum HeifVerdict {
  /// The bytes are not a HEIF/HEIC container at all.
  notHeif,

  /// A HEIF still image without an alpha auxiliary image.
  noAlpha,

  /// A HEIF still image that carries an alpha auxiliary image.
  alpha,

  /// The header could not be read within the byte budget (or was unreadable).
  unknown,
}

/// A safe, log-only summary of a still's container header.
class HeifHeader {
  const HeifHeader(
    this.verdict, {
    this.brand = '',
    this.auxUrn = '',
    this.auxReferences = 0,
    this.auxItems = 0,
    this.bytes = 0,
  });

  const HeifHeader.unknown({this.bytes = 0})
    : verdict = HeifVerdict.unknown,
      brand = '',
      auxUrn = '',
      auxReferences = 0,
      auxItems = 0;

  final HeifVerdict verdict;

  /// Major brand of `ftyp`, e.g. `heic`.
  final String brand;

  /// `auxid1` / `cicp_alpha` when an alpha `auxC` property was found.
  final String auxUrn;

  /// `iref` entries of type `auxl` and `iinf` items of type `auxl`.
  final int auxReferences;
  final int auxItems;

  /// Bytes the decision was made from (never a size of the whole file).
  final int bytes;

  bool get isHeif => verdict != HeifVerdict.notHeif;
  bool get hasAlpha => verdict == HeifVerdict.alpha;

  /// Fixed log fields.
  String get logFields =>
      'heif=${verdict.name} brand=${brand.isEmpty ? '-' : brand} '
      'alpha_urn=${auxUrn.isEmpty ? '-' : auxUrn} '
      'aux_refs=$auxReferences aux_items=$auxItems head_bytes=$bytes';
}

/// Whether this device cannot show [header] even though the file is intact.
bool heifAlphaUndisplayable(HeifHeader header, int? sdkInt) =>
    header.hasAlpha &&
    sdkInt != null &&
    kHeicAlphaUnsupportedSdk.contains(sdkInt);

/// Reads and decides the header of [path]. Never reads the whole file: at most
/// [headBytes], plus one bounded read of a `meta` box that sits past the head.
Future<HeifHeader> readHeifHeaderOfFile(
  String path, {
  int headBytes = kHeifHeadBytes,
}) async {
  RandomAccessFile? file;
  try {
    file = await File(path).open();
    final length = await file.length();
    if (length <= 0) return const HeifHeader.unknown();
    final head = await _readAt(file, 0, length < headBytes ? length : headBytes);
    final header = parseHeifHeader(head);
    if (header.verdict != HeifVerdict.unknown) return header;
    // A `meta` box past the head (a mdat-first writer): follow the top-level
    // box chain by headers only, then read that one box inside the budget.
    final meta = await _seekBox(file, length, 'meta');
    if (meta == null) return header;
    final available = (length - meta.$1).clamp(0, kHeifMetaBytes);
    if (available <= 0) return header;
    final payload = await _readAt(file, meta.$1, available);
    // The read starts at the FullBox header, so the children start 4 bytes in.
    return _decideMeta(payload, 4, payload.length, header.brand, head.length);
  } catch (_) {
    return const HeifHeader.unknown();
  } finally {
    try {
      await file?.close();
    } catch (_) {}
  }
}

/// Payload offset of the top-level [type] box, found by walking box headers
/// only (16 bytes each, at most 32 hops). Never reads a payload.
Future<(int, int)?> _seekBox(
  RandomAccessFile file,
  int length,
  String type,
) async {
  var at = 0;
  for (var hop = 0; hop < 32 && at + 8 <= length; hop++) {
    final header = await _readAt(file, at, 16);
    final size = _u32(header, 0);
    final name = _fourCc(header, 4);
    var headerBytes = 8;
    var total = size;
    if (size == 1) {
      if (header.length < 16) return null;
      total = _u64(header, 8);
      headerBytes = 16;
    } else if (size == 0) {
      total = length - at;
    }
    if (total < headerBytes) return null;
    if (name == type) return (at + headerBytes, total);
    at += total;
  }
  return null;
}

Future<Uint8List> _readAt(RandomAccessFile file, int offset, int length) async {
  await file.setPosition(offset);
  final bytes = await file.read(length);
  return Uint8List.fromList(bytes);
}

/// Decides a still's container from [bytes]. Pure; every read is bounds checked.
HeifHeader parseHeifHeader(Uint8List bytes) {
  if (bytes.length < 12) return const HeifHeader.unknown();
  String brand = '';
  _Span? meta;
  for (final box in _boxes(bytes, 0, bytes.length)) {
    if (box.type == 'ftyp') {
      final major = _fourCc(bytes, box.payload);
      if (!kHeifStillBrands.contains(major)) {
        return HeifHeader(
          HeifVerdict.notHeif,
          brand: _safe(major),
          bytes: bytes.length,
        );
      }
      brand = major;
    } else if (box.type == 'meta') {
      meta = box;
    }
  }
  if (brand.isEmpty) return HeifHeader(HeifVerdict.notHeif, bytes: bytes.length);
  if (meta == null) {
    // A HEIF still always declares its meta box; without it the header was cut
    // short by the byte budget.
    return HeifHeader(
      HeifVerdict.unknown,
      brand: _safe(brand),
      bytes: bytes.length,
    );
  }
  // The box itself is a FullBox: version + flags, then its children.
  return _decideMeta(bytes, meta.payload + 4, meta.end, brand, bytes.length);
}

HeifHeader _decideMeta(
  Uint8List bytes,
  int start,
  int end,
  String brand,
  int readBytes,
) {
  final facts = _MetaFacts();
  var recognisable = 0;
  for (final child in _boxes(bytes, start, end)) {
    switch (child.type) {
      case 'iinf':
        recognisable++;
        _walkIinf(bytes, child, facts);
      case 'iref':
        recognisable++;
        _walkIref(bytes, child, facts);
      case 'iprp':
        recognisable++;
        _walkIprp(bytes, child, facts);
    }
  }
  if (recognisable == 0) {
    // The meta box is there but nothing this build knows how to read: that is
    // no answer either, and no answer never rejects a file.
    return HeifHeader(
      HeifVerdict.unknown,
      brand: _safe(brand),
      bytes: readBytes,
    );
  }
  final verdict = facts.alphaUsed ? HeifVerdict.alpha : HeifVerdict.noAlpha;
  return HeifHeader(
    verdict,
    brand: _safe(brand),
    auxUrn: facts.alphaUrn,
    auxReferences: facts.auxReferences,
    auxItems: facts.auxItems,
    bytes: readBytes,
  );
}

class _Span {
  const _Span(this.type, this.start, this.payload, this.size);

  final String type;
  final int start;

  /// Offset of the payload (after the 8- or 16-byte box header).
  final int payload;

  /// Total box size in bytes, header included.
  final int size;

  int get end => start + size;
}

/// Walks sibling boxes in `[start, end)`. Stops at the first malformed box, so a
/// truncated buffer yields exactly the boxes it fully holds.
List<_Span> _boxes(Uint8List bytes, int start, int end) {
  final result = <_Span>[];
  var at = start;
  var guard = 0;
  while (at + 8 <= end && guard++ < 4096) {
    final size = _u32(bytes, at);
    final type = _fourCc(bytes, at + 4);
    if (size == 0) {
      // Extends to the end of the enclosing container.
      result.add(_Span(type, at, at + 8, end - at));
      break;
    }
    var header = 8;
    var total = size;
    if (size == 1) {
      if (at + 16 > end) break;
      total = _u64(bytes, at + 8);
      header = 16;
    }
    if (total < header || at + total > end) break;
    result.add(_Span(type, at, at + header, total));
    at += total;
  }
  return result;
}

class _MetaFacts {
  /// Property index -> fixed token of the alpha URN it carries.
  final alphaProperties = <int, String>{};

  /// How many `ipma` associations point at an alpha `auxC` property.
  int alphaAssociations = 0;

  /// Whether an `auxl` reference or item declared an auxiliary image.
  int auxReferences = 0;
  int auxItems = 0;

  String get alphaUrn => alphaProperties.values.firstOrNull ?? '';

  /// An alpha still is a HEIC whose `auxC` alpha property is *used*: either
  /// associated with an item through `ipma`, or accompanied by an `auxl`
  /// item/reference. A file that merely defines the property is not one.
  bool get alphaUsed =>
      alphaProperties.isNotEmpty &&
      (alphaAssociations > 0 || auxReferences > 0 || auxItems > 0);
}

void _walkIinf(Uint8List bytes, _Span box, _MetaFacts facts) {
  final version = bytes[box.payload];
  var at = box.payload + 4;
  if (version == 0 ? at + 2 > box.end : at + 4 > box.end) return;
  at += version == 0 ? 2 : 4;
  for (final infe in _boxes(bytes, at, box.end)) {
    if (infe.type != 'infe' || infe.payload + 4 > infe.end) continue;
    final v = bytes[infe.payload];
    var cursor = infe.payload + 4;
    // An auxl item carries the alpha plane; the id itself is not needed here.
    final idWidth = v >= 3 ? 4 : 2;
    cursor += idWidth + 2; // item_ID + item_protection_index
    if (v >= 2 && cursor + 4 <= infe.end) {
      if (_fourCc(bytes, cursor) == 'auxl') facts.auxItems++;
    }
  }
}

void _walkIref(Uint8List bytes, _Span box, _MetaFacts facts) {
  // Only the reference *type* matters here: an `auxl` reference from the primary
  // image to an auxiliary item is what an alpha plane looks like. The ids and
  // their width (version 0 = 16 bit, 1 = 32 bit) are skipped, not read.
  for (final ref in _boxes(bytes, box.payload + 4, box.end)) {
    if (ref.type == 'auxl') facts.auxReferences++;
  }
}

void _walkIprp(Uint8List bytes, _Span box, _MetaFacts facts) {
  final children = _boxes(bytes, box.payload, box.end);
  final ipco = children.where((c) => c.type == 'ipco').firstOrNull;
  if (ipco != null) {
    var index = 0;
    for (final property in _boxes(bytes, ipco.payload, ipco.end)) {
      index++;
      if (property.type != 'auxC') continue;
      final urn = _cString(bytes, property.payload + 4, property.end);
      if (urn == kAlphaAuxUrnHevc) {
        facts.alphaProperties[index] = 'auxid1';
      } else if (urn == kAlphaAuxUrnCicp) {
        facts.alphaProperties[index] = 'cicp_alpha';
      }
    }
  }
  // `ipma` lists which item uses which property index. It is read so a file
  // that merely *defines* an unused alpha property is not mistaken for a file
  // that uses one.
  final ipma = children.where((c) => c.type == 'ipma').firstOrNull;
  if (ipma != null && facts.alphaProperties.isNotEmpty) {
    facts.alphaAssociations = _alphaAssociations(
      bytes,
      ipma,
      facts.alphaProperties.keys.toSet(),
    );
  }
}

int _alphaAssociations(Uint8List bytes, _Span box, Set<int> alphaIndexes) {
  final version = bytes[box.payload];
  final wideIndexes = (bytes[box.payload + 3] & 1) == 1;
  if (box.payload + 8 > box.end) return 0;
  final entries = _u32(bytes, box.payload + 4);
  var at = box.payload + 8;
  var used = 0;
  for (var entry = 0; entry < entries && at < box.end; entry++) {
    at += version < 1 ? 2 : 4; // item_ID
    if (at >= box.end) break;
    final count = bytes[at];
    at += 1;
    for (var i = 0; i < count && at < box.end; i++) {
      final index = wideIndexes ? _u16(bytes, at) & 0x7fff : bytes[at] & 0x7f;
      at += wideIndexes ? 2 : 1;
      if (alphaIndexes.contains(index)) used++;
    }
  }
  return used;
}

int _u16(Uint8List bytes, int at) =>
    at + 2 > bytes.length ? 0 : (bytes[at] << 8) | bytes[at + 1];

int _u32(Uint8List bytes, int at) =>
    at + 4 > bytes.length ? 0 : ByteData.sublistView(bytes).getUint32(at);

int _u64(Uint8List bytes, int at) =>
    at + 8 > bytes.length ? 0 : ByteData.sublistView(bytes).getUint64(at);

String _fourCc(Uint8List bytes, int at) {
  if (at + 4 > bytes.length) return '';
  return String.fromCharCodes(bytes.sublist(at, at + 4));
}

String _cString(Uint8List bytes, int start, int end) {
  final buffer = StringBuffer();
  for (var at = start; at < end && at < bytes.length; at++) {
    if (bytes[at] == 0) break;
    buffer.writeCharCode(bytes[at]);
  }
  return buffer.toString();
}

/// Only a short printable token may reach a log line.
String _safe(String value) =>
    RegExp(r'^[A-Za-z0-9_.-]{1,16}$').hasMatch(value) ? value : '';

/// Whether a still's container is a HEIF this build decides from bytes.
bool isHeifExtension(String? extension) =>
    const {'heic', 'heif'}.contains((extension ?? '').toLowerCase());
