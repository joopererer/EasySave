import 'dart:async';

import 'package:easysave/services/links.dart';
import 'package:easysave/services/parse_service.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reported XHS /o/ short link is recognized and expanded offline', () async {
    SiteRegistry.useBuiltin();
    const input = 'https://xhslink.cn/o/3REdoqhbg6s';
    const target = 'https://www.xiaohongshu.com/explore/6adb3258000000002c00da14?xsec_token=example';
    expect(extractLink('share $input'), input);
    final site = SiteRegistry.current.match(input)!;
    expect(site.id, 'xhs');
    var reads = 0;
    await resolveAndEnterParse(input, site, (load, canonical) async {
      expect(load, target);
      expect(canonical, 'https://www.xiaohongshu.com/explore/6adb3258000000002c00da14');
    }, readRedirect: (_) async => reads++ == 0 ? target : null);
    expect(reads, 2);
  });
  // v1.9.0 parity per site: xhslink/t.co expand over HTTP, TikTok short links
  // are followed by the WebView, and a full post URL is entered unchanged.
  final httpCases = <(String, String, List<String>, String, String?)>[
    (
      'xhs',
      'https://xhslink.cn/o/71TKM3kfsK1',
      [
        'https://xhslink.com/71TKM3kfsK1',
        'https://www.xiaohongshu.com/discovery/item/AbC123?xsec_token=keep',
      ],
      'https://www.xiaohongshu.com/discovery/item/AbC123?xsec_token=keep',
      'https://www.xiaohongshu.com/explore/AbC123',
    ),
    (
      'xhs',
      'https://xhslink.com/AbC123',
      ['https://www.xiaohongshu.com/explore/AbC123'],
      'https://www.xiaohongshu.com/explore/AbC123',
      'https://www.xiaohongshu.com/explore/AbC123',
    ),
    (
      'x',
      'https://t.co/AbC123',
      ['https://x.com/creator/status/2115654865154191715?a=token'],
      'https://x.com/creator/status/2115654865154191715?a=token',
      'https://x.com/i/status/2115654865154191715',
    ),
    (
      'instagram',
      'https://www.instagram.com/p/DfE4G_WiP52/?srtk=token',
      [],
      'https://www.instagram.com/p/DfE4G_WiP52/?srtk=token',
      'https://www.instagram.com/p/DfE4G_WiP52/',
    ),
  ];

  for (final (id, input, hops, loadUrl, canonical) in httpCases) {
    test('$id http short-link pipeline enters parser with correct URL', () async {
      SiteRegistry.useBuiltin();
      final site = SiteRegistry.current.match(input)!;
      expect(site.id, id);
      var calls = 0;
      var entered = false;
      final result = await resolveAndEnterParse(
        input,
        site,
        (actualLoad, actualCanonical) async {
          entered = true;
          expect(actualLoad, loadUrl);
          expect(actualCanonical, canonical);
          return 'entered';
        },
        readRedirect: (uri) async => calls < hops.length ? hops[calls++] : null,
        timeout: Duration(milliseconds: site.load['timeoutMs'] as int),
      );
      expect(result, 'entered');
      expect(entered, isTrue);
      expect(calls, hops.length);
    });
  }

  // TikTok declares `strategy: webview`, so no HTTP expansion may run: the
  // token/cookie-bearing landing hop belongs to the WebView (v1.9.0).
  final tiktokShortLinks = [
    'https://vm.tiktok.com/ZN8UuWyMb/',
    'https://vt.tiktok.com/AbC123/',
    'https://www.tiktok.com/t/ZN8UuWyMb/',
  ];
  for (final input in tiktokShortLinks) {
    test('tiktok short link $input is handed to the WebView untouched', () async {
      SiteRegistry.useBuiltin();
      final site = SiteRegistry.current.match(input)!;
      expect(site.id, 'tiktok');
      final rule = site.shortLink(Uri.parse(input))!;
      expect(rule['strategy'], 'webview');
      expect(rule['historyStrategy'], 'http');
      var reads = 0;
      final result = await resolveAndEnterParse(
        input,
        site,
        (actualLoad, actualCanonical) async {
          expect(actualLoad, input);
          expect(actualCanonical, isNull);
          return 'entered';
        },
        readRedirect: (_) async {
          reads++;
          return 'https://www.tiktok.com/@creator/video/1234567890123456789';
        },
      );
      expect(result, 'entered');
      expect(reads, 0, reason: 'webview short links must not be HTTP expanded');
    });
  }

  test('tiktok history lookup still expands over HTTP', () async {
    SiteRegistry.useBuiltin();
    const input = 'https://vm.tiktok.com/ZN8UuWyMb/';
    var reads = 0;
    final resolved = await resolveShortLink(
      input,
      forHistoryLookup: true,
      readRedirect: (_) async {
        reads++;
        return reads == 1
            ? 'https://www.tiktok.com/@creator/video/1234567890123456789'
            : null;
      },
    );
    expect(reads, 2);
    expect(resolved, 'https://www.tiktok.com/@creator/video/1234567890123456789');
  });

  test('XHS short link without an HTTP redirect falls back to WebView', () async {
    SiteRegistry.useBuiltin();
    const input = 'https://xhslink.cn/o/71TKM3kfsK1';
    final site = SiteRegistry.current.match(input)!;
    final result = await resolveAndEnterParse(
        input,
        site,
        (load, canonical) async {
          expect(load, input);
          expect(canonical, isNull);
          return 'webview';
        },
        readRedirect: (_) async => null,
      );
    expect(result, 'webview');
  });

  test('short link expansion respects declared timeout', () async {
    SiteRegistry.useBuiltin();
    const input = 'https://xhslink.cn/o/71TKM3kfsK1';
    final site = SiteRegistry.current.match(input)!;
    final result = await resolveAndEnterParse(
        input,
        site,
        (load, canonical) async {
          expect(load, input);
          expect(canonical, isNull);
          return 'webview';
        },
        readRedirect: (_) => Completer<String?>().future,
        timeout: const Duration(milliseconds: 20),
      );
    expect(result, 'webview');
  });

  test('HTTP terminal redirects are retried in WebView before classification', () async {
    SiteRegistry.useBuiltin();
    const input = 'https://xhslink.cn/o/71TKM3kfsK1';
    final site = SiteRegistry.current.match(input)!;
    for (final path in ['/login', '/captcha', '/404']) {
      final result = await resolveAndEnterParse(input, site, (load, canonical) async {
          expect(load, input);
          expect(canonical, isNull);
          return 'webview';
        },
          readRedirect: (_) async => 'https://www.xiaohongshu.com$path');
      expect(result, 'webview');
    }
  });

  test('XHS short links landing on home fail without waiting for WebView', () async {
    SiteRegistry.useBuiltin();
    const input = 'https://xhslink.cn/o/fixture';
    final site = SiteRegistry.current.match(input)!;
    for (final path in ['/', '/explore', '/explore/']) {
      await expectLater(
        resolveAndEnterParse(input, site, (_, _) async => fail('must not parse'),
          readRedirect: (_) async => 'https://www.xiaohongshu.com$path'),
        throwsA(isA<ParseFailure>().having((e) => e.code, 'code', 'UNSUPPORTED_URL')),
      );
    }
    expect(terminalPageFailure(site, Uri.parse('https://www.rednote.com/explore/abc')), isNull);
  });

  test('XHS profile post routes share the declared canonical ID', () {
    SiteRegistry.useBuiltin();
    for (final domain in ['www.xiaohongshu.com', 'www.rednote.com']) {
      final url = 'https://$domain/user/profile/author/670f1a2b000000001e028b12';
      expect(SiteRegistry.current.match(url)?.id, 'xhs');
      expect(SiteRegistry.current.canonicalUrl(url),
          'https://www.xiaohongshu.com/explore/670f1a2b000000001e028b12');
    }
  });

  test('HTTP ending on another short-link page falls back to original link', () async {
    SiteRegistry.useBuiltin();
    const input = 'https://xhslink.cn/o/71TKM3kfsK1';
    final site = SiteRegistry.current.match(input)!;
    var calls = 0;
    final result = await resolveAndEnterParse(input, site, (load, canonical) async {
      expect(load, input);
      expect(canonical, isNull);
      return 'webview';
    }, readRedirect: (_) async => calls++ == 0 ? 'https://xhslink.com/landing' : null);
    expect(result, 'webview');
  });

  test('cached older manifest inherits builtin terminal and short-link defaults', () async {
    SiteRegistry.useBuiltin();
    final builtin = SiteRegistry.current.byId('xhs')!;
    final old = SiteDefinition({
      ...builtin.data,
      'load': {...builtin.load}..remove('terminalPages'),
      'shortLinks': [
        for (final raw in builtin.data['shortLinks'] as List)
          {...raw as Map<String, dynamic>}..remove('fallbackStrategy'),
      ],
    });
    expect(terminalPageFailure(old, Uri.parse('https://www.xiaohongshu.com/login'))?.code, 'LOGIN_REQUIRED');
    final uri = Uri.parse('https://xhslink.cn/o/abc');
    expect(old.shortLinkFallback(uri, old.shortLink(uri)!), 'webview');
    final explicit = {...old.shortLink(uri)!, 'fallbackStrategy': 'none'};
    expect(old.shortLinkFallback(uri, explicit), 'none');
  });

  test('HTML redirect diagnostics expose only a fixed category', () {
    expect(shortLinkHtmlKind('text/html', '<meta http-equiv="refresh" content="0">'), 'meta');
    expect(shortLinkHtmlKind('text/html', '<script>window.location.href="hidden"</script>'), 'js');
    expect(shortLinkHtmlKind('text/html', '<p>text</p>'), 'none');
    expect(shortLinkHtmlKind('application/json', '{}'), 'not_html');
  });

  test('short link cannot enter a different site', () async {
    SiteRegistry.useBuiltin();
    const input = 'https://t.co/AbC123';
    final site = SiteRegistry.current.match(input)!;
    await expectLater(
      resolveAndEnterParse(
        input,
        site,
        (_, _) async => fail('parser must not run'),
        readRedirect: (_) async => 'https://evil.example/post/123',
      ),
      throwsA(
        isA<ParseFailure>().having(
          (e) => e.message,
          'message',
          contains('不受支持'),
        ),
      ),
    );
  });
}
