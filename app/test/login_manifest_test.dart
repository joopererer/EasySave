import 'dart:convert';
import 'dart:io';
import 'package:easysave/services/auth.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(SiteRegistry.useBuiltin);

  test('four login entries match pre-migration auth and MinePage at 24fb900', () {
    // Old MinePage iterated PlatformKind.values; auth.dart supplied these URLs.
    const before = {
      'xhs': 'https://www.xiaohongshu.com/explore',
      'instagram': 'https://www.instagram.com/accounts/login/',
      'x': 'https://x.com/i/flow/login',
      'tiktok': 'https://www.tiktok.com/login',
    };
    final source =
        (jsonDecode(File('../config/sites.json').readAsStringSync()) as List)
            .cast<Map<String, dynamic>>();
    for (final definitions in [
      source,
      SiteRegistry.current.sites.map((s) => s.data),
    ]) {
      SiteRegistry.activate(definitions);
      expect(loginSiteIds, orderedEquals(before.keys));
      for (final entry in before.entries) {
        expect(loginEntryUrl(entry.key), entry.value);
        expect(SiteRegistry.current.byId(entry.key)!.auth['mode'], 'optional');
      }
    }
  });

  test('only enabled optional and required sites have login entries', () {
    SiteRegistry.activate([
      for (final mode in ['none', 'optional', 'required'])
        for (final enabled in [false, true])
          {
            'id': '${mode}_$enabled',
            'platform': '${mode}_$enabled',
            'enabled': enabled,
            'auth': {'mode': mode, 'loginUrl': 'https://example.test/login'},
          },
    ]);
    expect(loginSiteIds, ['optional_true', 'required_true']);
    expect(hasAccountHook('optional_true'), false);
  });
}
