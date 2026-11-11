import 'package:easysave/services/auth.dart';
import 'package:easysave/services/links.dart';
import 'package:easysave/services/parse_service.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const postId = '670f1a2b000000001e028b12';
  const shortUrl = 'https://xhslink.cn/o/offline';
  const rednote =
      'https://www.rednote.com/discovery/item/$postId'
      '?xsec_token=synthetic_token&xsec_source=pc_share';
  const mainland =
      'https://www.xiaohongshu.com/discovery/item/$postId'
      '?xsec_token=synthetic_token&xsec_source=pc_share';

  setUp(() {
    SiteRegistry.useBuiltin();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(SiteRegistry.useBuiltin);

  Future<void> session(String domain, SessionStatus status) =>
      saveXhsDomainStatus(domain, status);

  for (final entry in [
    'app_input',
    'share',
    'bubble_select',
    'history',
    'cache',
    'webview_redirect',
  ]) {
    test('final loading boundary applies domain policy for $entry', () async {
      await session('xiaohongshu.com', SessionStatus.valid);
      final selected = await chooseFinalParseUrl(
        rednote,
        SiteRegistry.current.byId('xhs')!,
        entry: entry,
      );
      expect(Uri.parse(selected).host, 'www.xiaohongshu.com');
      expect(
        Uri.parse(selected).queryParameters,
        Uri.parse(rednote).queryParameters,
      );
    });
  }

  test(
    'HTTP expansion stops at the first supported post before alias redirect',
    () async {
      final visited = <String>[];
      final result = await resolveShortLink(
        shortUrl,
        readRedirect: (uri) async {
          visited.add(uri.toString());
          if (visited.length == 1) return mainland;
          if (visited.length == 2) return rednote;
          return null;
        },
      );
      expect(result, mainland);
      expect(visited, [
        shortUrl,
      ], reason: 'The post Location must not be fetched without cookies');
    },
  );

  test('hop two rednote Location uses the valid mainland session', () async {
    await session('xiaohongshu.com', SessionStatus.valid);
    var hops = 0;
    await resolveAndEnterParse(
      shortUrl,
      SiteRegistry.current.byId('xhs')!,
      (load, canonical) async {
        expect(Uri.parse(load).host, 'www.xiaohongshu.com');
        expect(
          Uri.parse(load).queryParameters,
          Uri.parse(rednote).queryParameters,
        );
      },
      readRedirect: (_) async {
        hops++;
        if (hops == 1) return 'https://xhslink.com/intermediate';
        if (hops == 2) return rednote;
        fail('must not request a supported post without cookies');
      },
    );
    expect(hops, 2);
  });

  for (final valid in ['xiaohongshu.com', 'rednote.com']) {
    test(
      'resolved rednote post chooses the only valid domain: $valid',
      () async {
        await session(
          'xiaohongshu.com',
          valid == 'xiaohongshu.com'
              ? SessionStatus.valid
              : SessionStatus.invalid,
        );
        await session(
          'rednote.com',
          valid == 'rednote.com' ? SessionStatus.valid : SessionStatus.invalid,
        );
        final site = SiteRegistry.current.byId('xhs')!;
        await resolveAndEnterParse(
          shortUrl,
          site,
          (load, canonical) async {
            final uri = Uri.parse(load);
            expect(uri.host, 'www.$valid');
            expect(site.sourceId(uri), postId);
            expect(uri.queryParameters['xsec_token'], 'synthetic_token');
            expect(uri.queryParameters['xsec_source'], 'pc_share');
            expect(canonical, site.canonical(postId));
          },
          readRedirect: (uri) async =>
              uri.toString() == shortUrl ? rednote : null,
        );
      },
    );
  }

  test(
    'both invalid domains retain the original resolved post address',
    () async {
      await session('xiaohongshu.com', SessionStatus.invalid);
      await session('rednote.com', SessionStatus.invalid);
      final site = SiteRegistry.current.byId('xhs')!;
      await resolveAndEnterParse(
        shortUrl,
        site,
        (load, _) async {
          expect(load, rednote);
        },
        readRedirect: (uri) async =>
            uri.toString() == shortUrl ? rednote : null,
      );
      expect(
        terminalPageFailure(
          site,
          Uri.parse('https://www.rednote.com/login'),
        )?.code,
        'LOGIN_REQUIRED',
      );
    },
  );

  test('direct rednote post still chooses a valid mainland alias', () async {
    await session('xiaohongshu.com', SessionStatus.valid);
    await session('rednote.com', SessionStatus.invalid);
    final site = SiteRegistry.current.byId('xhs')!;
    await resolveAndEnterParse(rednote, site, (load, _) async {
      expect(Uri.parse(load).host, 'www.xiaohongshu.com');
      expect(Uri.parse(load).queryParameters['xsec_token'], 'synthetic_token');
    });
  });

  test(
    'valid original rednote domain wins when both domains are valid',
    () async {
      await session('xiaohongshu.com', SessionStatus.valid);
      await session('rednote.com', SessionStatus.valid);
      final site = SiteRegistry.current.byId('xhs')!;
      await resolveAndEnterParse(rednote, site, (load, _) async {
        expect(load, rednote);
      });
    },
  );
}
