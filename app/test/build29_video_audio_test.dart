import 'dart:io';
import 'dart:typed_data';

import 'package:easysave/core/models.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/mp4_audio_probe.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _box(String type, List<int> body) {
  final size = 8 + body.length;
  return Uint8List.fromList([
    (size >> 24) & 0xff, (size >> 16) & 0xff, (size >> 8) & 0xff, size & 0xff,
    ...type.codeUnits,
    ...body,
  ]);
}

Uint8List _track(String handler) => _box('trak', [
  ..._box('tkhd', List.filled(84, 0)),
  ..._box('mdia', [
    ..._box('mdhd', List.filled(24, 0)),
    ..._box('hdlr', [0, 0, 0, 0, 0, 0, 0, 0, ...handler.codeUnits, ...List.filled(13, 0)]),
  ]),
]);

/// ftyp, moov with the given track handlers, then an mdat payload.
Uint8List _mp4(List<String> handlers, {bool moovLast = false}) {
  final ftyp = _box('ftyp', [...'isom'.codeUnits, 0, 0, 2, 0]);
  final moov = _box('moov', [
    ..._box('mvhd', List.filled(100, 0)),
    for (final handler in handlers) ..._track(handler),
  ]);
  final mdat = _box('mdat', List.filled(256, 7));
  return Uint8List.fromList(
    moovLast ? [...ftyp, ...mdat, ...moov] : [...ftyp, ...moov, ...mdat],
  );
}

DownloadJob _videoJob({int urls = 2, bool live = false, bool image = false}) =>
    DownloadJob(
      key: 'job',
      label: '视频 1',
      filename: 'v.mp4',
      urls: [for (var i = 0; i < urls; i++) 'https://v.example/$i.mp4'],
      isImage: image,
      itemIndex: 1,
      isLivePhoto: live,
    );

void main() {
  group('MP4 audio track detection', () {
    test('finds a soun handler in moov/trak/mdia/hdlr', () {
      expect(mp4BytesHaveAudioTrack(_mp4(['vide', 'soun'])), isTrue);
      expect(mp4BytesHaveAudioTrack(_mp4(['vide'])), isFalse);
      expect(mp4BytesHaveAudioTrack(_mp4([])), isNull);
      expect(mp4BytesHaveAudioTrack(Uint8List.fromList('not an mp4'.codeUnits)), isNull);
    });

    test('reads files with moov before or after the media data', () async {
      final dir = await Directory.systemTemp.createTemp('easysave_mp4');
      addTearDown(() => dir.delete(recursive: true));
      Future<bool?> probe(Uint8List bytes, String name) async {
        final file = File('${dir.path}/$name.mp4');
        await file.writeAsBytes(bytes);
        return mp4HasAudioTrack(file);
      }

      expect(await probe(_mp4(['vide', 'soun']), 'front'), isTrue);
      expect(await probe(_mp4(['vide', 'soun'], moovLast: true), 'tail'), isTrue);
      expect(await probe(_mp4(['vide'], moovLast: true), 'silent'), isFalse);
      expect(await probe(Uint8List(3), 'short'), isNull);
    });
  });

  group('no-audio retry', () {
    test('a silent video moves on to the next candidate URL', () async {
      final job = _videoJob()..attempts = 1;
      expect(
        await shouldRetryForMissingAudio(job, 'x', probe: (_) async => false),
        isTrue,
      );
      expect(
        await shouldRetryForMissingAudio(job, 'x', probe: (_) async => true),
        isFalse,
      );
      expect(
        await shouldRetryForMissingAudio(job, 'x', probe: (_) async => null),
        isFalse,
      );
    });

    test('the last candidate, images and Live Photo clips are kept', () async {
      Future<bool?> silent(String _) async => false;
      expect(
        await shouldRetryForMissingAudio(_videoJob()..attempts = 2, 'x', probe: silent),
        isFalse,
      );
      expect(
        await shouldRetryForMissingAudio(_videoJob(urls: 1)..attempts = 1, 'x', probe: silent),
        isFalse,
      );
      expect(
        await shouldRetryForMissingAudio(_videoJob(live: true)..attempts = 1, 'x', probe: silent),
        isFalse,
      );
      expect(
        await shouldRetryForMissingAudio(_videoJob(image: true)..attempts = 1, 'x', probe: silent),
        isFalse,
      );
    });

    test('video candidates are tried in parser rank order', () {
      final post = ParsedPost(
        platform: 'xhs',
        id: 'p',
        url: 'https://www.xiaohongshu.com/explore/p',
        author: PostAuthor(),
        items: [
          MediaItem(
            type: 'video',
            url: 'https://sns-video-bd.xhscdn.com/stream/with-audio.mp4',
            fallbacks: ['https://sns-video-bd.xhscdn.com/pre_post/origin'],
          ),
        ],
      );
      final planned = planFiles(post, [0], (l, s, e) => 'f$s.$e').single;
      expect(planned.urls, [
        'https://sns-video-bd.xhscdn.com/stream/with-audio.mp4',
        'https://sns-video-bd.xhscdn.com/pre_post/origin',
      ]);
    });
  });
}
