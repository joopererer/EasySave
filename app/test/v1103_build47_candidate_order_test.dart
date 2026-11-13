// v1.10.3 build 47 — what the first candidate of a still actually is.
//
// Build 46 preflighted 252,532 bytes for the first image of 6af1ad13, byte for
// byte the size the post's preview cache holds. The cause was the ranking: the
// parser's own order puts the CDN's default-quality JPEG transcode
// (`ci…?imageView2/format/jpg`, 245,672 bytes for a 1,007,645-byte original at
// the same 1290x1608) first, and the full-quality transcode this build derives
// (`?imageView2/format/jpg/q/100`, 1,030,648 bytes) tied with it, losing on the
// stable tie-break. Both are original-resolution candidates — neither is the
// preview — but the first one the app asked for was the small one.
//
// This test pins the order: the full-quality JPEG transcode of the original
// token is asked for first, the default-quality transcode second, and any
// preview-size URL last.

import 'dart:convert';
import 'dart:io';

import 'package:easysave/core/models.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/media_content_type.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:flutter_test/flutter_test.dart';

const _token = '/notes_pre_post/1040g3k83264voo1al0dg5o2e1l408pfcf1dl208';
const _original = 'https://sns-img-bd.xhscdn.com$_token';
const _derived = '$_original?imageView2/format/jpg/q/100';
const _ciJpeg = 'https://ci.xiaohongshu.com$_token?imageView2/format/jpg';
const _ciOriginal = 'https://ci.xiaohongshu.com$_token';
const _webpic =
    'https://sns-webpic-qc.xhscdn.com/202610112129/abc$_token!nd_prv_wlteh_webp_3';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(SiteRegistry.useBuiltin);
  tearDown(SiteRegistry.useBuiltin);

  test('the derived full-quality transcode is not mistaken for the default '
      'quality one', () {
    expect(isDefaultQualityTranscode(_ciJpeg), isTrue);
    expect(isDefaultQualityTranscode(_derived), isFalse);
    expect(isDefaultQualityTranscode(_original), isFalse);
    expect(isDefaultQualityTranscode(_ciOriginal), isFalse);
    expect(isDefaultQualityTranscode(_webpic), isFalse);
    // `format/jpeg` is byte-identical to `format/jpg` on this CDN.
    expect(
      isDefaultQualityTranscode(
        'https://ci.xiaohongshu.com$_token?imageView2/format/jpeg',
      ),
      isTrue,
    );
  });

  test('the parser order plus the derived candidate ranks the full-quality '
      'transcode first', () {
    // What the parser's `downloadOrder` hands over for one XHS image: the
    // default-quality transcode, then the original bucket, then bare ci.
    final fromParser = [_ciJpeg, _original, _ciOriginal, _webpic];
    final ranked = rankStillCandidates(withDerivedJpegOriginals(fromParser));

    expect(ranked.first, _derived,
        reason: 'the first request must be the full-quality transcode');
    expect(ranked[1], _ciJpeg, reason: 'the small transcode comes second');
    expect(isPreviewStillCandidate(ranked.first), isFalse);
    expect(isPreviewStillCandidate(ranked[1]), isFalse);
    expect(ranked.last, _webpic, reason: 'previews are the last resort');
    expect(ranked, hasLength(fromParser.length + 1));
  });

  test("a still's planned first URL is an original-resolution transcode of the "
      'post token, never a preview', () {
    // A real post body from the fixture corpus (no downloadOrder: the legacy
    // adapter path), so the plan is built from the declared fallbacks.
    final fixture = jsonDecode(
      File('../spec/fixtures/xhs/xhs_multi.expected.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final item = MediaItem.fromJson(
      (fixture['items'] as List).first as Map<String, dynamic>,
    );
    final job = DownloadJob(
      key: 'job-1',
      label: '图片 1',
      filename: 'post_1.jpg',
      urls: rankStillCandidates(
        filterMediaCandidates(
          withDerivedJpegOriginals([...item.fallbacks, item.url]),
          isImage: true,
        ),
      ),
      isImage: true,
      itemIndex: 1,
    );
    final first = job.urls.first;
    expect(isPreviewStillCandidate(first), isFalse);
    expect(isDefaultQualityTranscode(first), isFalse);
    expect(Uri.parse(first).host, 'sns-img-bd.xhscdn.com');
    expect(Uri.parse(first).query, kJpegOriginalQuery);
    expect(Uri.parse(first).path, Uri.parse(item.url).path,
        reason: 'the same token the post declared');
    // The label the preflight line now prints for that candidate.
    expect(candidateLabelOf(first), 'img:jpg');
    expect(candidateLabelOf(_ciJpeg), 'ci:jpg');
    expect(candidateLabelOf(_webpic), 'webpic');
  });
}
