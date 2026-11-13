// v1.10.3 build 47 — every download was blocked by the app's own request
// policy.
//
// Build 46 logged `REQUEST_HEADER_REJECTED` for ci.xiaohongshu.com,
// sns-video-zl.xhscdn.com, scontent-*.cdninstagram.com and video.twimg.com.
// The cause was `unifiedTransferHeaders()` adding `Accept-Encoding: identity`
// after the policy had approved the request, and the native consumers of that
// header map (the background downloader and the preview fetch) re-checking the
// same whitelist on every hop.
//
// This test assembles a real download request for all four sites and both
// media kinds — real `MediaRequestPolicy.authorize()` over the bundled site
// definitions, real `unifiedTransferHeaders()` — and asserts the result is
// accepted. Nothing under test is mocked: the only seam is the platform cookie
// jar, which is a dependency of `authorize()` and not the thing being checked.
//
// TikTok kept working in build 46 because its video transport is the in-process
// session download, which never re-validates the map; XHS / IG / X transfer
// through the background downloader. Both transports are covered here.

import 'dart:io';

import 'package:easysave/core/media_request.dart';
import 'package:easysave/core/models.dart';
import 'package:easysave/services/media_request_policy.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:easysave/services/transfer_headers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// One real media URL per site and kind, using the hosts build 46 rejected
/// (or their siblings), so a whitelist regression names the site it hits.
const _cases = <String, Map<String, String>>{
  'xhs': {
    'image':
        'https://sns-img-bd.xhscdn.com/notes_pre_post/1040g3k83264voo1al0dg5o2e1l408pfcf1dl208',
    'image-ci':
        'https://ci.xiaohongshu.com/notes_pre_post/1040g3k83264voo1al0dg5o2e1l408pfcf1dl208?imageView2/format/jpg/q/100',
    'video':
        'https://sns-video-zl.xhscdn.com/stream/1/10/19/01ea342f_19.mp4?sign=temporary',
  },
  'instagram': {
    'image': 'https://scontent-fra3-1.cdninstagram.com/v/t51.2885-15/still.jpg',
    'video': 'https://scontent-fra3-1.cdninstagram.com/o1/v/t16/f1/m86/clip.mp4',
  },
  'x': {
    'image': 'https://pbs.twimg.com/media/GVxyz123.jpg',
    'video': 'https://video.twimg.com/ext_tw_video/1/pu/vid/720x1280/clip.mp4',
  },
  'tiktok': {
    'image': 'https://p16-common-sign.tiktokcdn-eu.com/tos-useast2a-p-0037/photo.jpg',
    'video': 'https://v16-webapp-prime.tiktok.com/video/tos/clip.mp4',
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(SiteRegistry.useBuiltin);
  tearDown(SiteRegistry.useBuiltin);

  /// Validates the map the native side will see, over a real policy.
  void expectAcceptedByPolicy(
    String siteId,
    MediaRequestResource declared,
    Map<String, String> wire,
  ) {
    final policy = MediaRequestPolicy(
      SiteRegistry.current.byId(siteId)!,
      readCookie: (_) async => 'sessionid=test',
    );
    final resource = MediaRequestResource(
      role: declared.role,
      url: declared.url,
      fallbackFor: declared.fallbackFor,
      request: MediaRequestRequirements(
        headers: wire,
        cookieDomains: declared.request.cookieDomains,
        expiresAt: declared.request.expiresAt,
        transport: declared.request.transport,
        resumable: declared.request.resumable,
      ),
    );
    expect(
      () => policy.validate(resource),
      returnsNormally,
      reason: '$siteId ${declared.role.name} must accept its own transfer '
          'headers: $wire',
    );
    // Every name is whitelisted and nothing was smuggled in.
    for (final name in wire.keys) {
      expect(
        kAllowedRequestHeaderNames.contains(name.toLowerCase()),
        isTrue,
        reason: '$siteId $name is not a whitelisted request header',
      );
    }
  }

  for (final siteId in _cases.keys) {
    test('$siteId image and video requests survive authorize + transfer '
        'headers', () async {
      final site = SiteRegistry.current.byId(siteId)!;
      final policy = MediaRequestPolicy(
        site,
        readCookie: (_) async => 'sessionid=test',
      );
      for (final entry in _cases[siteId]!.entries) {
        final isVideo = entry.key.startsWith('video');
        final item = MediaItem(type: isVideo ? 'video' : 'image', url: entry.value);
        final resources = policy.resourcesFor(item);
        expect(resources, isNotEmpty);

        for (final declared in resources) {
          final authorized = await policy.authorize(declared);
          final wire = unifiedTransferHeaders(authorized.headers);
          debugPrint(
            'SELFTEST site=$siteId kind=${entry.key} '
            'host=${Uri.parse(entry.value).host} '
            'headers=${wire.keys.join(",")} '
            'encoding=${wire['Accept-Encoding']}',
          );

          // The two headers this build adds on top of the declaration.
          expect(wire['Accept-Encoding'], kTransferAcceptEncoding);
          expect(wire['User-Agent'], kTransferUserAgent);
          expect(kTransferAcceptEncoding, 'identity');
          // A declared value always wins over the default.
          if (declared.request.headers.containsKey('User-Agent')) {
            expect(wire['User-Agent'], declared.request.headers['User-Agent']);
          }
          expectAcceptedByPolicy(siteId, declared, wire);

          // The ranged preflight asks the same CDN for one byte; the Range it
          // adds is whitelisted too, so the probe cannot be refused on its own.
          final preflight = unifiedTransferHeaders({
            ...authorized.headers,
            'Range': 'bytes=0-0',
          });
          expect(preflight['Range'], 'bytes=0-0');
          expectAcceptedByPolicy(siteId, declared, preflight);

          // The cookie never leaks into the header map the native side checks.
          expect(wire.keys, isNot(contains('Cookie')));
        }
      }
    });
  }

  test('every host class rejected by build 46 is covered by this test', () {
    // The device log listed ci.xiaohongshu.com, sns-video-zl.xhscdn.com,
    // scontent-*.cdninstagram.com and video.twimg.com. A future edit that drops
    // one of them from the cases must fail here rather than in the field.
    final hosts = <String>{
      for (final cases in _cases.values)
        for (final url in cases.values) Uri.parse(url).host,
    };
    for (final required in const [
      'ci.xiaohongshu.com',
      'sns-video-zl.xhscdn.com',
      'scontent-fra3-1.cdninstagram.com',
      'video.twimg.com',
    ]) {
      expect(hosts, contains(required));
    }
  });

  test('the native whitelist is the same list as the Dart policy', () {
    // A background transfer re-checks the header map in Kotlin. Reading the
    // source keeps the lists from drifting apart again — the build 46
    // regression was exactly such a drift.
    const pluginKt =
        'vendor/background_downloader/android/src/main/kotlin/'
        'com/bbflight/background_downloader/MediaPolicyRedirects.kt';
    final source = File(pluginKt).readAsStringSync();
    final permitted = RegExp(
      r'PERMITTED_HEADERS\s*=\s*setOf\(([^)]*)\)',
    ).firstMatch(source);
    expect(permitted, isNotNull, reason: '$pluginKt must declare its header set');
    final names = RegExp(
      r'"([a-z-]+)"',
    ).allMatches(permitted!.group(1)!).map((m) => m.group(1)!).toSet();
    expect(
      names,
      kAllowedRequestHeaderNames,
      reason: 'the plugin must permit exactly the Dart names',
    );
    expect(
      source,
      contains('"accept-encoding" to setOf("identity")'),
      reason: 'the transfer encoding is whitelisted for identity only',
    );
    // The preview fetch re-checks through the same object instead of keeping a
    // third copy of the list.
    final requestKt = File(
      'android/app/src/main/kotlin/com/james/easysave/NativeMediaRequest.kt',
    ).readAsStringSync();
    expect(requestKt, contains('MediaPolicyRedirects.PERMITTED_HEADERS'));
    expect(requestKt, contains('MediaPolicyRedirects.PERMITTED_VALUES'));
  });

  test('a rejected transfer header names itself without its value', () {
    final logs = <String>[];
    final policy = MediaRequestPolicy(
      SiteRegistry.current.byId('xhs')!,
      readCookie: (_) async => '',
      logRejection: (code, host) => logs.add('$code $host'),
    );
    expect(
      () => policy.validate(
        MediaRequestResource(
          role: MediaResourceRole.image,
          url: 'https://sns-img-bd.xhscdn.com/notes_pre_post/token',
          request: MediaRequestRequirements(
            headers: {'Accept-Encoding': 'gzip'},
            transport: MediaTransport.background,
            resumable: true,
          ),
        ),
      ),
      throwsA(isA<MediaPolicyException>()),
    );
    expect(logs, ['REQUEST_HEADER_REJECTED sns-img-bd.xhscdn.com']);
  });
}
