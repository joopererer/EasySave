// Copyright 2026 EasySave. All rights reserved.
// v1.11 build 58: one final URL is tried once.
//
// Parser 1.4.17 will generate the `imageView2/format/jpg/q/100` original itself,
// while this build derives the same candidate from the parser's own token (see
// `withDerivedJpegOriginals`). Both orders must therefore end up with each final
// URL exactly once — before the parser release and after it — so an item never
// spends two attempts on the same bytes.

import 'package:easysave/core/models.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/image_format_preference.dart';
import 'package:easysave/services/media_content_type.dart';
import 'package:flutter_test/flutter_test.dart';

const _token = 'spectrum/1040g0k031abcdefghij005n7t8q9r0';
const _original = 'https://sns-img-bd.xhscdn.com/$_token';
const _derived = '$_original?imageView2/format/jpg/q/100';
const _parserJpeg = '$_original?imageView2/format/jpg/q/100';
const _preview = 'https://sns-webpic-qc.xhscdn.com/$_token!nd_prv_wlteh_webp_3';
const _video = 'https://sns-video-bd.xhscdn.com/stream/abc.mp4';

/// No URL may appear twice in a ladder.
void _expectUnique(List<String> urls) {
  expect(urls.toSet(), hasLength(urls.length),
      reason: 'the same final URL must never be queued twice');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the still ladder keeps every final URL once', () {
    test('the derived jpeg candidate is not added when the parser sent it', () {
      final urls = stillCandidatesFor(
        [_original, _parserJpeg],
        formatPref: ImageFormatPreference.compat,
      );
      _expectUnique(urls);
      expect(
        urls.where((url) => url == _parserJpeg),
        hasLength(1),
        reason: 'parser 1.4.17 and the App derive the same candidate',
      );
      expect(urls.first, _parserJpeg);
    });

    test('a parser that only sends the original gets one derived candidate', () {
      final urls = stillCandidatesFor(
        [_original],
        formatPref: ImageFormatPreference.compat,
      );
      _expectUnique(urls);
      expect(urls.where((url) => url == _derived), hasLength(1));
    });

    test('a duplicate token in the parser list collapses', () {
      final urls = stillCandidatesFor(
        [_original, _original, _parserJpeg],
        formatPref: ImageFormatPreference.compat,
      );
      _expectUnique(urls);
      expect(urls, hasLength(2));
    });

    test('the original preference dedupes too', () {
      final urls = stillCandidatesFor(
        [_original, _original, _parserJpeg, _preview, _preview],
        formatPref: ImageFormatPreference.original,
      );
      _expectUnique(urls);
      expect(urls.first, _original);
      expect(urls.last, _preview);
    });

    test('the jpeg preference dedupes too', () {
      final urls = stillCandidatesFor(
        [_original, _parserJpeg, _parserJpeg],
        formatPref: ImageFormatPreference.jpeg,
      );
      _expectUnique(urls);
      expect(urls, [_parserJpeg]);
    });

    test('dedupeFinalCandidates keeps the first occurrence, in order', () {
      expect(
        dedupeFinalCandidates(['a', 'b', 'a', 'c', 'b']),
        ['a', 'b', 'c'],
      );
    });
  });

  group('a planned file carries each URL once', () {
    ParsedPost post(List<MediaItem> items) => ParsedPost(
      platform: 'xhs',
      id: 'dedup',
      url: 'https://www.xiaohongshu.com/explore/dedup',
      author: PostAuthor(name: 'tester'),
      items: items,
    );

    test('a still whose fallbacks repeat the original', () {
      final planned = planFiles(
        post([
          MediaItem(
            type: 'image',
            url: _original,
            fallbacks: [_original, _derived, _original],
          ),
        ]),
        [0],
        (_, seq, _) => 'img_$seq',
      ).single;
      _expectUnique(planned.urls);
      expect(planned.urls, hasLength(2), reason: 'the original and one jpeg');
    });

    test('a video whose fallbacks repeat the primary URL', () {
      final planned = planFiles(
        post([
          MediaItem(
            type: 'video',
            url: _video,
            fallbacks: [_video, _video],
          ),
        ]),
        [0],
        (_, seq, _) => 'vid_$seq',
      ).single;
      expect(planned.urls, [_video]);
    });

    test('a Live photo keeps its still and clip apart', () {
      final planned = planFiles(
        post([
          MediaItem(
            type: 'live',
            url: _original,
            videoUrl: _video,
            fallbacks: [_original],
          ),
        ]),
        [0],
        (_, seq, ext) => 'live_${seq}_$ext',
      );
      expect(planned, hasLength(2));
      for (final file in planned) {
        _expectUnique(file.urls);
      }
      expect(planned.where((f) => !f.isImage).single.urls, [_video],
          reason: 'a still URL must never be fetched as a motion clip');
    });

    test('the retry planner dedupes the same way', () {
      final urls = planFilesForItem(
        post([
          MediaItem(
            type: 'image',
            url: _original,
            fallbacks: [_parserJpeg, _original],
          ),
        ]),
        0,
      );
      expect(urls, isNotNull);
      _expectUnique(urls!);
    });
  });
}
