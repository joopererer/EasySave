import 'dart:async';

import 'package:easysave/services/parse_service.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final cases = <(String, String, List<String>, String, String)>[
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
      'tiktok',
      'https://vm.tiktok.com/ZN8UuWyMb/',
      [
        'https://www.tiktok.com/t/ZN8UuWyMb/',
        'https://www.tiktok.com/@creator/video/1234567890123456789?is_from_webapp=1',
      ],
      'https://www.tiktok.com/@creator/video/1234567890123456789?is_from_webapp=1',
      'https://www.tiktok.com/@/video/1234567890123456789',
    ),
    (
      'tiktok',
      'https://vt.tiktok.com/AbC123/',
      ['https://www.tiktok.com/@creator/photo/1234567890123456789'],
      'https://www.tiktok.com/@creator/photo/1234567890123456789',
      'https://www.tiktok.com/@/video/1234567890123456789',
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

  for (final (id, input, hops, loadUrl, canonical) in cases) {
    test('$id short-link pipeline enters parser with correct URL', () async {
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

  test('short link that never redirects fails clearly', () async {
    SiteRegistry.useBuiltin();
    const input = 'https://vm.tiktok.com/ZN8UuWyMb/';
    final site = SiteRegistry.current.match(input)!;
    await expectLater(
      resolveAndEnterParse(
        input,
        site,
        (_, _) async => fail('parser must not run'),
        readRedirect: (_) async => null,
      ),
      throwsA(
        isA<ParseFailure>().having(
          (e) => e.message,
          'message',
          contains('短链未能展开'),
        ),
      ),
    );
  });

  test('short link expansion respects declared timeout', () async {
    SiteRegistry.useBuiltin();
    const input = 'https://xhslink.cn/o/71TKM3kfsK1';
    final site = SiteRegistry.current.match(input)!;
    await expectLater(
      resolveAndEnterParse(
        input,
        site,
        (_, _) async => fail('parser must not run'),
        readRedirect: (_) => Completer<String?>().future,
        timeout: const Duration(milliseconds: 20),
      ),
      throwsA(isA<TimeoutException>()),
    );
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
