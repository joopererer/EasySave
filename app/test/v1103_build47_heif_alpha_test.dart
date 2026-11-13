// v1.10.3 build 47 — HEIC support decided from the container bytes.
//
// The eight sample files from the device report are not in the repository, so
// this test builds the two shapes the rule has to separate from the ISO-BMFF
// structure itself (only fixtures are added, nothing existing is changed):
//
//  * a HEIC with an alpha auxiliary image — `iinf` declares an `auxl` item,
//    `iref` links the primary image to it and `ipco` carries an `auxC` property
//    with one of the two alpha URNs. Android 12's decoder hangs on these.
//  * a HEIC without one — no `auxl` item, no `auxl` reference, no alpha `auxC`.
//
// The parser reads `ftyp`, `meta`/`iinf`, `meta`/`iref` and
// `meta`/`iprp`/`ipco`/`auxC` (+ `ipma`) and never calls a decoder, so it cannot
// hang: the only limit is the byte budget, and an unreadable header stays
// `unknown` (which never rejects a file).

import 'dart:io';
import 'dart:typed_data';

import 'package:easysave/services/heif_bytes.dart';
import 'package:easysave/services/image_decode_probe.dart';
import 'package:easysave/services/media_content_type.dart';
import 'package:flutter_test/flutter_test.dart';

List<int> _u16(int value) => [(value >> 8) & 0xff, value & 0xff];

List<int> _u32(int value) => [
  (value >> 24) & 0xff,
  (value >> 16) & 0xff,
  (value >> 8) & 0xff,
  value & 0xff,
];

Uint8List _box(String type, List<int> payload) => Uint8List.fromList([
  ..._u32(8 + payload.length),
  ...type.codeUnits,
  ...payload,
]);

Uint8List _fullBox(String type, int version, List<int> payload) =>
    _box(type, [version, 0, 0, 0, ...payload]);

List<int> _ascii(String value) => value.codeUnits;

List<int> _ftyp({String major = 'heic'}) => [
  ..._u32(8 + 4 + 4 + 4 + 4),
  ..._ascii('ftyp'),
  ..._ascii(major),
  ..._u32(0),
  ..._ascii('mif1'),
  ..._ascii(major),
];

/// `infe` version 2 for one item; [itemType] is the four-character type.
List<int> _infe(int id, String itemType) => _fullBox('infe', 2, [
  ..._u16(id),
  ..._u16(0), // item_protection_index
  ..._ascii(itemType),
  0, // empty item_name
]);

List<int> _iinf(List<int> entries, {int count = 2}) =>
    _fullBox('iinf', 0, [..._u16(count), ...entries]);

List<int> _irefAuxl({int from = 1, int to = 2}) =>
    _fullBox('iref', 0, [
      ..._u32(8 + 2 + 2 + 2),
      ..._ascii('auxl'),
      ..._u16(from),
      ..._u16(1), // reference_count
      ..._u16(to),
    ]);

List<int> _iprp({required List<List<int>> properties, List<int>? ipma}) => _box(
  'iprp',
  [
    ..._box('ipco', [for (final property in properties) ...property]),
    ...?ipma,
  ],
);

/// `ipma` associating property index [index] with item [itemId].
List<int> _ipma(int itemId, int index) => _fullBox('ipma', 0, [
  ..._u32(1), // entry_count
  ..._u16(itemId),
  1, // association_count
  index & 0x7f, // essential bit clear, index
]);

List<int> _auxC(String urn) => _fullBox('auxC', 0, [..._ascii(urn), 0]);

Uint8List _heic({required bool alpha, String urn = kAlphaAuxUrnHevc}) {
  final properties = <List<int>>[
    _box('hvcC', List.filled(12, 0)),
    if (alpha) _auxC(urn),
  ];
  return Uint8List.fromList([
    ..._ftyp(),
    ..._fullBox('meta', 0, [
      ..._iinf([
        ..._infe(1, 'hvc1'),
        if (alpha) ..._infe(2, 'auxl'),
      ], count: alpha ? 2 : 1),
      if (alpha) ..._irefAuxl(),
      ..._iprp(
        properties: properties,
        ipma: alpha ? _ipma(2, 2) : null,
      ),
    ]),
    ..._box('mdat', List.filled(64, 3)),
  ]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => ImageDecodeProbe.setApiLevelForTesting(null));

  test('a HEIC with an alpha auxiliary image is detected', () {
    final header = parseHeifHeader(_heic(alpha: true));
    expect(header.verdict, HeifVerdict.alpha);
    expect(header.hasAlpha, isTrue);
    expect(header.isHeif, isTrue);
    expect(header.brand, 'heic');
    expect(header.auxUrn, 'auxid1');
    expect(header.auxReferences, 1);
    expect(header.auxItems, 1);
    expect(header.logFields, contains('heif=alpha'));
    expect(header.logFields, isNot(contains('http')));
  });

  test('the CICP alpha URN is recognised too', () {
    final header = parseHeifHeader(
      _heic(alpha: true, urn: kAlphaAuxUrnCicp),
    );
    expect(header.verdict, HeifVerdict.alpha);
    expect(header.auxUrn, 'cicp_alpha');
  });

  test('a HEIC without an alpha auxiliary image is not flagged', () {
    final header = parseHeifHeader(_heic(alpha: false));
    expect(header.verdict, HeifVerdict.noAlpha);
    expect(header.hasAlpha, isFalse);
    expect(header.brand, 'heic');
    expect(header.auxUrn, isEmpty);
  });

  test('an alpha property that no item uses is not an alpha still', () {
    // The property exists in `ipco` but `ipma` never associates it, and no
    // `auxl` item or reference is declared.
    final bytes = Uint8List.fromList([
      ..._ftyp(),
      ..._fullBox('meta', 0, [
        ..._iinf([..._infe(1, 'hvc1')], count: 1),
        ..._iprp(properties: [_box('hvcC', List.filled(12, 0)), _auxC(kAlphaAuxUrnHevc)]),
      ]),
    ]);
    expect(parseHeifHeader(bytes).verdict, HeifVerdict.noAlpha);
  });

  test('other containers are not HEIF', () {
    final jpeg = Uint8List.fromList([0xff, 0xd8, 0xff, 0xe0, ...List.filled(40, 0)]);
    expect(parseHeifHeader(jpeg).verdict, HeifVerdict.notHeif);
    final mp4 = Uint8List.fromList([
      ..._u32(16),
      ..._ascii('ftyp'),
      ..._ascii('isom'),
      ..._u32(0),
    ]);
    expect(parseHeifHeader(mp4).verdict, HeifVerdict.notHeif);
    expect(parseHeifHeader(Uint8List(4)).verdict, HeifVerdict.unknown);
  });

  test('a header cut short stays unknown instead of guessing', () {
    final bytes = _heic(alpha: true);
    // ftyp only: the meta box was not read.
    final truncated = Uint8List.fromList(bytes.sublist(0, 24));
    expect(parseHeifHeader(truncated).verdict, HeifVerdict.unknown);
  });

  test('only the listed Android levels reject an alpha HEIC', () {
    final alpha = parseHeifHeader(_heic(alpha: true));
    final plain = parseHeifHeader(_heic(alpha: false));
    expect(heifAlphaUndisplayable(alpha, 31), isTrue, reason: 'Android 12');
    expect(heifAlphaUndisplayable(alpha, 30), isFalse);
    expect(heifAlphaUndisplayable(alpha, 33), isFalse);
    expect(heifAlphaUndisplayable(alpha, null), isFalse);
    expect(heifAlphaUndisplayable(plain, 31), isFalse);
    expect(kHeicAlphaUnsupportedSdk, {31});
  });

  test('a file is read from its head, and a meta box past the head is found by '
      'box header only', () async {
    final dir = await Directory.systemTemp.createTemp('easysave_heif');
    try {
      // meta first (the usual iPhone layout).
      final normal = File('${dir.path}/alpha.heic');
      await normal.writeAsBytes(_heic(alpha: true));
      final head = await readHeifHeaderOfFile(normal.path);
      expect(head.verdict, HeifVerdict.alpha);

      // mdat first, meta at the end: the head cannot hold the meta box, so the
      // reader has to follow the box chain and read just that box.
      final late = File('${dir.path}/late.heic');
      final bytes = _heic(alpha: true);
      final ftyp = bytes.sublist(0, 24);
      final rest = bytes.sublist(24);
      await late.writeAsBytes([
        ...ftyp,
        ..._u32(8 + 400 * 1024),
        ..._ascii('mdat'),
        ...List.filled(400 * 1024, 0),
        ...rest,
      ]);
      final lateHead = await readHeifHeaderOfFile(late.path);
      expect(lateHead.verdict, HeifVerdict.alpha);
      expect(lateHead.bytes, lessThan(600 * 1024),
          reason: 'never reads the whole file');

      // A file with no meta at all cannot be decided.
      final broken = File('${dir.path}/broken.heic');
      await broken.writeAsBytes([
        ..._ftyp(),
        ..._box('mdat', List.filled(32, 1)),
      ]);
      expect((await readHeifHeaderOfFile(broken.path)).verdict,
          HeifVerdict.unknown);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('the download gate rejects an alpha HEIC on Android 12 without ever '
      'calling a decoder', () async {
    final dir = await Directory.systemTemp.createTemp('easysave_gate');
    const heic = MediaContentType(
      MediaContentKind.image,
      'heic',
      'image/heic',
    );
    try {
      final alpha = File('${dir.path}/alpha.heic');
      await alpha.writeAsBytes(_heic(alpha: true));
      final plain = File('${dir.path}/plain.heic');
      await plain.writeAsBytes(_heic(alpha: false));

      ImageDecodeProbe.setApiLevelForTesting(31);
      final rejected = await StillDecodeGate.forStoredStill(heic, alpha.path);
      expect(rejected.probed, isTrue);
      expect(rejected.rejected, isTrue);
      expect(rejected.result!.decoder, heifByteDecoder);
      expect(rejected.result!.reason, heifAlphaReason);
      expect(rejected.logFields, contains('device_probe=undecodable'));

      // The same file on a level that is not listed keeps the old behaviour.
      ImageDecodeProbe.setApiLevelForTesting(33);
      final allowed = await StillDecodeGate.forStoredStill(heic, alpha.path);
      expect(allowed.rejected, isFalse);

      // A HEIC without an alpha plane is accepted even on Android 12.
      ImageDecodeProbe.setApiLevelForTesting(31);
      final fine = await StillDecodeGate.forStoredStill(heic, plain.path);
      expect(fine.probed, isTrue);
      expect(fine.rejected, isFalse);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('a JPEG never reaches the HEIF reader', () async {
    final dir = await Directory.systemTemp.createTemp('easysave_gate_jpeg');
    try {
      final jpeg = File('${dir.path}/still.jpg');
      await jpeg.writeAsBytes([0xff, 0xd8, 0xff, 0xe0, ...List.filled(40, 0)]);
      final gate = await StillDecodeGate.forStoredStill(
        const MediaContentType(MediaContentKind.image, 'jpg', 'image/jpeg'),
        jpeg.path,
      );
      expect(gate.probed, isFalse);
      expect(gate.logFields, isEmpty);
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
