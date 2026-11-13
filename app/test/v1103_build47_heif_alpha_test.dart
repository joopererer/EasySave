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

  tearDown(() {
    ImageDecodeProbe.setApiLevelForTesting(null);
    ImageDecodeProbe.callForTesting = null;
    ImageDecodeProbe.timeout = const Duration(seconds: 4);
  });

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

  group('the alpha HEIC rule by Android level', () {
    final alpha = parseHeifHeader(_heic(alpha: true));
    final plain = parseHeifHeader(_heic(alpha: false));

    test('every level from Android 9 to 12L rejects an alpha HEIC', () {
      for (final sdk in [28, 29, 30, 31, 32]) {
        expect(heifAlphaUndisplayable(alpha, sdk), isTrue,
            reason: 'SDK $sdk is Android 9–12L');
        expect(heifAlphaNeedsDeviceProbe(alpha, sdk), isFalse,
            reason: 'SDK $sdk is decided from bytes, no decoder is asked');
      }
      expect(kHeicAlphaUnsupportedMaxSdk, 32);
      expect(kHeicAlphaProbeMinSdk, 33);
    });

    test('from Android 13 on only the device decoder may answer', () {
      for (final sdk in [33, 34]) {
        expect(heifAlphaUndisplayable(alpha, sdk), isFalse,
            reason: 'SDK $sdk is not rejected by the container rule');
        expect(heifAlphaNeedsDeviceProbe(alpha, sdk), isTrue,
            reason: 'SDK $sdk has to be probed on the device');
      }
    });

    test('an unknown level neither rejects nor probes', () {
      expect(heifAlphaUndisplayable(alpha, null), isFalse);
      expect(heifAlphaNeedsDeviceProbe(alpha, null), isFalse);
    });

    test('a HEIC without an alpha plane is never rejected nor probed', () {
      for (final sdk in [28, 30, 31, 32, 33, 34, null]) {
        expect(heifAlphaUndisplayable(plain, sdk), isFalse, reason: 'SDK $sdk');
        expect(heifAlphaNeedsDeviceProbe(plain, sdk), isFalse, reason: 'SDK $sdk');
      }
    });
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

  test('the download gate rejects an alpha HEIC on Android 9–12L without ever '
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

      var probes = 0;
      ImageDecodeProbe.callForTesting = (method, arguments) async {
        probes++;
        return null;
      };

      for (final sdk in [28, 30, 31, 32]) {
        ImageDecodeProbe.setApiLevelForTesting(sdk);
        final rejected = await StillDecodeGate.forStoredStill(heic, alpha.path);
        expect(rejected.probed, isTrue, reason: 'SDK $sdk');
        expect(rejected.rejected, isTrue, reason: 'SDK $sdk');
        expect(rejected.result!.decoder, heifByteDecoder, reason: 'SDK $sdk');
        expect(rejected.result!.reason, heifAlphaReason, reason: 'SDK $sdk');
        expect(rejected.logFields, contains('device_probe=undecodable'));
      }
      expect(probes, 0,
          reason: 'a HEIC on SDK ≤ 32 never reaches the native decoder');

      // A HEIC without an alpha plane is accepted even on Android 12.
      ImageDecodeProbe.setApiLevelForTesting(31);
      final fine = await StillDecodeGate.forStoredStill(heic, plain.path);
      expect(fine.probed, isTrue);
      expect(fine.rejected, isFalse);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('from Android 13 on the gate asks the device decoder', () async {
    final dir = await Directory.systemTemp.createTemp('easysave_gate_probe');
    const heic = MediaContentType(
      MediaContentKind.image,
      'heic',
      'image/heic',
    );
    try {
      final alpha = File('${dir.path}/alpha.heic');
      await alpha.writeAsBytes(_heic(alpha: true));

      var probes = 0;
      for (final (sdk, decodable) in [(33, true), (33, false), (34, true), (34, false)]) {
        probes = 0;
        ImageDecodeProbe.setApiLevelForTesting(sdk);
        ImageDecodeProbe.callForTesting = (method, arguments) async {
          probes++;
          expect(method, 'probeImageDecodable');
          return {
            'decodable': decodable,
            'width': 1536,
            'height': 2560,
            'sampleWidth': decodable ? 192 : 0,
            'sampleHeight': decodable ? 320 : 0,
            'decoder': 'bitmapfactory',
            'reason': decodable ? 'ok' : 'decode_failed',
            'bytes': 78054,
          };
        };
        final gate = await StillDecodeGate.forStoredStill(heic, alpha.path);
        expect(probes, 1, reason: 'SDK $sdk decodable=$decodable');
        expect(gate.probed, isTrue);
        expect(gate.rejected, decodable ? isFalse : isTrue,
            reason: 'SDK $sdk decodable=$decodable');
        expect(gate.result!.verdict,
            decodable ? ImageDecodeVerdict.decodable : ImageDecodeVerdict.undecodable);
      }
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('a probe that does not answer stays unknown: never rejected, never '
      'treated as missing', () async {
    final dir = await Directory.systemTemp.createTemp('easysave_gate_timeout');
    const heic = MediaContentType(
      MediaContentKind.image,
      'heic',
      'image/heic',
    );
    try {
      final alpha = File('${dir.path}/alpha.heic');
      await alpha.writeAsBytes(_heic(alpha: true));
      ImageDecodeProbe.setApiLevelForTesting(33);
      ImageDecodeProbe.timeout = const Duration(milliseconds: 10);
      ImageDecodeProbe.callForTesting = (method, arguments) async {
        // A decode that never comes back inside the timeout.
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return {'decodable': false};
      };

      final gate = await StillDecodeGate.forStoredStill(heic, alpha.path);
      expect(gate.probed, isTrue);
      expect(gate.rejected, isFalse, reason: 'no answer must not reject');
      expect(gate.result!.verdict, ImageDecodeVerdict.unknown);
      expect(gate.result!.reason, 'timeout');
      expect(await alpha.exists(), isTrue,
          reason: 'the gate itself must not delete anything');
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('an unknown level does not probe and does not reject', () async {
    final dir = await Directory.systemTemp.createTemp('easysave_gate_nullsdk');
    const heic = MediaContentType(
      MediaContentKind.image,
      'heic',
      'image/heic',
    );
    try {
      final alpha = File('${dir.path}/alpha.heic');
      await alpha.writeAsBytes(_heic(alpha: true));
      var probes = 0;
      ImageDecodeProbe.callForTesting = (method, arguments) async {
        probes++;
        return null;
      };
      ImageDecodeProbe.setApiLevelForTesting(null);

      final gate = await StillDecodeGate.forStoredStill(heic, alpha.path);
      expect(probes, 0, reason: 'no platform answer, so nothing is asked');
      expect(gate.rejected, isFalse);
      expect(gate.result!.verdict, ImageDecodeVerdict.decodable);
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
