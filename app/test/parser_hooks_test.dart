import 'dart:convert';
import 'package:easysave/services/parse_service.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(SiteRegistry.useBuiltin);
  Map<String, dynamic> post(SiteDefinition site) => {
    'ok': true,
    'data': {
      'platform': site.platform,
      'id': site.normalization['exampleId'],
      'url': site.canonical(site.normalization['exampleId']),
      'author': {'name': 'Name'},
      'caption': '',
      'items': [
        {'type': 'image', 'url': 'https://cdn.example.test/image.jpg'},
      ],
    },
  };
  test(
    'disabled sites remain identifiable for maintenance notices but not entry recognition',
    () {
      final source = SiteRegistry.current.byId('instagram')!;
      SiteRegistry.activate([
        {...source.data, 'enabled': false},
      ]);
      const url = 'https://www.instagram.com/p/AbC123/';
      expect(SiteRegistry.current.match(url), isNull);
      expect(
        SiteRegistry.current.match(url, includeDisabled: true)?.id,
        'instagram',
      );
    },
  );
  test('dispatch is determined by manifest module, independent of site id', () {
    final source = SiteRegistry.current.byId('instagram')!;
    final site = SiteDefinition({
      ...source.data,
      'id': 'new-site',
      'parserModule': 'module_v2',
    });
    final js = ParserHooks(
      'verified code',
      site,
    ).expression('ready', 'https://example.test/a?quote="');
    expect(js, startsWith('EasySaveParser.moduleCall("module_v2","ready",'));
    final payload = js.substring(js.indexOf('{"url"'), js.length - 1);
    expect(jsonDecode(payload)['site']['id'], 'new-site');
    expect(jsonDecode(payload)['url'], 'https://example.test/a?quote="');
  });
  test(
    'result URLs use the selected canonical template for every enabled site',
    () {
      for (final site in SiteRegistry.current.sites.where((s) => s.enabled)) {
        final value = post(site);
        value['data']['url'] = 'https://example.test/arbitrary';
        expect(
          validateParserResult(value, site).data.url,
          site.canonical(site.normalization['exampleId']),
        );
      }
    },
  );
  test('canonical metadata retains the declared load query parameters only', () {
    final site = SiteRegistry.current.byId('xhs')!;
    final value = post(site);
    value['data']['url'] +=
        '?xsec_token=a%2Bb%3D&xsec_source=pc_share&utm_source=tracking#fragment';
    final uri = Uri.parse(validateParserResult(value, site).data.url);
    expect(uri.queryParameters, {
      'xsec_token': 'a+b=',
      'xsec_source': 'pc_share',
    });
    expect(uri.fragment, isEmpty);
  });
  test('rejects mismatched platform, missing identity, and invalid media', () {
    final site = SiteRegistry.current.byId('instagram')!;
    for (final change in [
      (Map data) => data['platform'] = 'x',
      (Map data) => data['id'] = '',
      (Map data) => data['id'] = null,
      (Map data) => data['items'] = 'not-a-list',
      (Map data) => data['items'][0]['url'] = 'javascript:alert(1)',
      (Map data) => data['items'][0]['url'] =
          'https://user:secret@cdn.example.test/image',
      (Map data) => data['items'][0]['type'] = 'script',
    ]) {
      final value = post(site);
      change(value['data']);
      expect(
        () => validateParserResult(value, site),
        throwsA(isA<ParseFailure>()),
      );
    }
  });
  test('a media-less post is accepted like v1.9.0 instead of a mismatch', () {
    final site = SiteRegistry.current.byId('x')!;
    final value = post(site);
    value['data']['items'] = <Map>[];
    final outcome = validateParserResult(value, site);
    expect(outcome.data.items, isEmpty);
    expect(outcome.data.platform, 'x');
  });
  test('platform names are compared after mapping xhs <-> xiaohongshu', () {
    final site = SiteRegistry.current.byId('xhs')!;
    expect(site.platform, 'xiaohongshu');
    final value = post(site);
    value['data']['platform'] = 'xhs';
    final outcome = validateParserResult(value, site);
    // Persisted identity stays the app key the rest of the app uses.
    expect(outcome.data.platform, 'xhs');
    final upper = post(site);
    upper['data']['platform'] = 'XHS';
    expect(validateParserResult(upper, site).data.platform, 'xhs');
    final specName = post(site);
    specName['data']['platform'] = 'xiaohongshu';
    expect(validateParserResult(specName, site).data.platform, 'xhs');
  });
  test('numeric ids are normalized to strings before comparison', () {
    final site = SiteRegistry.current.byId('x')!;
    final value = post(site);
    value['data']['id'] = 2115654865154191715;
    final outcome = validateParserResult(value, site);
    expect(outcome.data.id, '2115654865154191715');
    expect(outcome.data.url, 'https://x.com/i/status/2115654865154191715');
  });
  test('preserves parser error code and readable message', () {
    final site = SiteRegistry.current.byId('instagram')!;
    expect(
      () => validateParserResult({
        'ok': false,
        'error': {'code': 'LOGIN_REQUIRED', 'message': 'Sign in'},
      }, site),
      throwsA(
        isA<ParseFailure>()
            .having((e) => e.code, 'code', 'LOGIN_REQUIRED')
            .having((e) => e.message, 'message', 'Sign in'),
      ),
    );
  });
}
