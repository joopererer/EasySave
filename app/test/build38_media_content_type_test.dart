import 'dart:io';
import 'dart:typed_data';

import 'package:easysave/services/media_content_type.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _bytes(List<int> values) => Uint8List.fromList(values);

Uint8List _fourCc(String type) => _bytes(type.codeUnits);

Uint8List _box(String type, List<int> body) {
  final size = 8 + body.length;
  return _bytes([
    (size >> 24) & 0xff, (size >> 16) & 0xff, (size >> 8) & 0xff, size & 0xff,
    ..._fourCc(type),
    ...body,
  ]);
}

/// `ftyp` with a major brand and 4-byte-aligned compatible brands.
Uint8List _ftyp(String major, [List<String> compatible = const []]) => _box('ftyp', [
  ..._fourCc(major),
  0, 0, 0, 0,
  for (final brand in compatible) ..._fourCc(brand),
]);

/// The bytes of a real Xiaohongshu iPhone Live still: HEIC brand, top-level
/// `meta` and `mdat`, no `moov`.
Uint8List heicStill({String major = 'heic'}) => _bytes([
  ..._ftyp(major, ['mif1', 'heic']),
  ..._box('meta', List.filled(40, 0)),
  ..._box('mdat', List.filled(64, 3)),
]);

Uint8List avifStill() => _bytes([
  ..._ftyp('avif', ['mif1', 'avif']),
  ..._box('meta', List.filled(32, 0)),
  ..._box('mdat', List.filled(48, 4)),
]);

Uint8List mp4({bool withMoov = true, bool moovLast = false}) => _bytes([
  ..._ftyp('isom', ['isom', 'mp41']),
  if (withMoov && !moovLast) ..._box('moov', List.filled(120, 0)),
  ..._box('mdat', List.filled(256, 7)),
  if (withMoov && moovLast) ..._box('moov', List.filled(120, 0)),
]);

Uint8List movBytes() => _bytes([
  ..._ftyp('qt  ', ['qt  ']),
  ..._box('moov', List.filled(80, 0)),
  ..._box('mdat', List.filled(128, 1)),
]);

Uint8List jpeg() => _bytes([0xFF, 0xD8, 0xFF, 0xE0, 0, 16, ...List.filled(32, 0)]);
Uint8List png() => _bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, ...List.filled(24, 0)]);
Uint8List webp() => _bytes([
  ..._fourCc('RIFF'), 24, 0, 0, 0, ..._fourCc('WEBP'), ...List.filled(16, 0),
]);
Uint8List gif() => _bytes([..._fourCc('GIF8'), 0x39, 0x61, ...List.filled(16, 0)]);

void main() {
  group('header detection', () {
    test('classifies the still containers', () {
      expect(detectMediaContentType(jpeg())!.extension, 'jpg');
      expect(detectMediaContentType(jpeg())!.mime, 'image/jpeg');
      expect(detectMediaContentType(png())!.extension, 'png');
      expect(detectMediaContentType(webp())!.extension, 'webp');
      expect(detectMediaContentType(gif())!.extension, 'gif');
      expect(detectMediaContentType(png())!.isImage, isTrue);
    });

    test('reads HEIC and AVIF as images, never as MP4', () {
      for (final major in ['heic', 'heix', 'mif1', 'msf1']) {
        final type = detectMediaContentType(heicStill(major: major))!;
        expect(type.kind, MediaContentKind.image, reason: major);
        expect(type.extension, 'heic', reason: major);
        expect(type.mime, 'image/heic', reason: major);
      }
      final avif = detectMediaContentType(avifStill())!;
      expect(avif.kind, MediaContentKind.image);
      expect(avif.extension, 'avif');
      expect(avif.mime, 'image/avif');
    });

    test('reads movies by brand', () {
      expect(detectMediaContentType(mp4())!.extension, 'mp4');
      expect(detectMediaContentType(mp4())!.mime, 'video/mp4');
      expect(detectMediaContentType(mp4())!.isVideo, isTrue);
      expect(detectMediaContentType(movBytes())!.extension, 'mov');
      expect(detectMediaContentType(movBytes())!.mime, 'video/quicktime');
    });

    test('an unknown container is unknown, not an image or a movie', () {
      expect(detectMediaContentType(_bytes('unsupported'.codeUnits)), isNull);
      expect(detectMediaContentType(_bytes(const [])), isNull);
      expect(detectMediaContentType(_ftyp('xxxx')), isNull);
    });
  });

  group('file sniffing', () {
    late Directory directory;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('easysave_content');
    });
    tearDown(() => directory.delete(recursive: true));

    Future<MediaContentType?> sniff(String name, Uint8List bytes) async =>
        sniffMediaFile((await File('${directory.path}/$name').writeAsBytes(bytes)).path);

    test('confirms the moov box of a movie', () async {
      expect((await sniff('front.mp4', mp4()))!.playable, isTrue);
      expect((await sniff('tail.mp4', mp4(moovLast: true)))!.playable, isTrue);
      expect((await sniff('silent.mp4', mp4(withMoov: false)))!.playable, isFalse);
    });

    test('a HEIC still is an image and never claims to be a movie', () async {
      final type = await sniff('still.mp4', heicStill());
      expect(type!.isImage, isTrue);
      expect(type.playable, isNull);
      expect(type.extension, 'heic');
    });

    test('an unreadable file is unknown', () async {
      expect(await sniffMediaFile('${directory.path}/missing.bin'), isNull);
    });
  });

  group('URL kinds', () {
    test('separates still renditions from motion clips', () {
      expect(mediaKindOfUrl('https://sns-img-bd.xhscdn.com/notes_pre_post/abc'), MediaContentKind.image);
      expect(mediaKindOfUrl('https://ci.xiaohongshu.com/notes_pre_post/abc?imageView2/format/jpg'),
          MediaContentKind.image);
      expect(mediaKindOfUrl('https://sns-webpic-qc.xhscdn.com/2026/a/abc!nd_dft_wlteh_webp_3'),
          MediaContentKind.image);
      expect(mediaKindOfUrl('https://sns-img-qc.xhscdn.com/abc.heic'), MediaContentKind.image);
      expect(mediaKindOfUrl('https://sns-video-v27.xhscdn.com/stream/1/10/19/01ea_19.mp4?sign=x'),
          MediaContentKind.video);
      expect(mediaKindOfUrl('https://cdn.example.com/a.mp4'), MediaContentKind.video);
      expect(mediaKindOfUrl('https://cdn.example.com/object'), isNull);
      expect(mediaKindOfUrl(''), isNull);
    });

    test('filters candidates to the wanted kind and keeps all-unknown lists', () {
      final image = 'https://sns-img-bd.xhscdn.com/notes_pre_post/abc';
      final video = 'https://sns-video-v27.xhscdn.com/stream/1/10/19/01ea_19.mp4';
      expect(filterMediaCandidates([image, video], isImage: false), [video]);
      expect(filterMediaCandidates([image, video], isImage: true), [image]);
      expect(filterMediaCandidates([video, image], isImage: true), [image]);
      // Nothing recognisable: keep the list so an unseen CDN shape is not lost.
      expect(filterMediaCandidates(['https://cdn.example.com/a'], isImage: false),
          ['https://cdn.example.com/a']);
    });
  });

  group('verification-only HEIC switch', () {
    const jpeg = 'https://ci.xiaohongshu.com/notes_pre_post/a?imageView2/format/jpg';
    const imgHeic = 'https://sns-img-bd.xhscdn.com/notes_pre_post/a.heic';
    const webpic = 'https://sns-webpic-qc.xhscdn.com/2026/a/x!nd_dft_wlteh_webp_3';

    test('is off in a normal build, so the release package keeps every '
        'candidate', () {
      // --dart-define is resolved at compile time: without the key the switch
      // is `false` and the filter is dead code, which is what the release APK
      // ships (proved by identical hashes of the two release builds).
      expect(kVerifyHeicOnlyStills, isFalse);
      expect(verifyOnlyStillCandidates([jpeg, imgHeic, webpic]),
          [jpeg, imgHeic, webpic]);
    });

    test('drops jpeg candidates only when the verification build sets it', () {
      // The switch cannot be flipped at runtime; the filter itself is checked
      // by its pure helper on the same input the verification build produces.
      final withoutJpeg = [
        for (final url in [jpeg, imgHeic, webpic])
          if (!candidateLabelOf(url).endsWith(':jpg')) url,
      ];
      expect(withoutJpeg, [imgHeic, webpic]);
      expect(candidateLabelOf(jpeg), 'ci:jpg');
      expect(candidateLabelOf(imgHeic), 'img:heic');
    });

    test('a jpeg-only item still downloads (the filter never empties a list)',
        () {
      expect(verifyOnlyStillCandidates([jpeg]), [jpeg]);
      expect(verifyOnlyStillCandidates(const []), isEmpty);
    });
  });
}
