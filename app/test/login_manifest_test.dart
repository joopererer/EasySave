import 'dart:convert';
import 'dart:io';
import 'package:easysave/core/models.dart';
import 'package:easysave/services/auth.dart';
import 'package:easysave/services/parse_service.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('a guest page on one XHS domain cannot clear the shared account', () {
    expect(shouldCachePageAccount('xhs', false), isFalse);
    expect(shouldCachePageAccount('xhs', true), isTrue);
    expect(shouldCachePageAccount('instagram', false), isTrue);
  });
  TestWidgetsFlutterBinding.ensureInitialized();
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

  test('a post login redirect does not invalidate the XHS account', () {
    LoginExpiredBus.clearAll();
    LoginExpiredBus.markParseLoginRequired('xhs');
    expect(LoginExpiredBus.expired.value, isNot(contains('xhs')));
    LoginExpiredBus.markParseLoginRequired('instagram');
    expect(LoginExpiredBus.expired.value, contains('instagram'));
    LoginExpiredBus.clearAll();
  });

  test('Rednote login redirect preserves a separately confirmed XHS session', () async {
    SharedPreferences.setMockInitialValues({});
    await AccountCache.save('xhs', const SiteAccount(loggedIn: true));
    LoginExpiredBus.clearAll();
    final site = SiteRegistry.current.byId('xhs')!;
    try {
      await navigateStep(
        site: site,
        currentUrl: 'https://www.rednote.com/login',
        alreadyNavigated: false,
        navigate: () async => null,
      );
      fail('login page should reject parsing');
    } on ParseFailure catch (error) {
      expect(error.code, ParseErrorCode.loginRequired);
      LoginExpiredBus.markParseLoginRequired('xhs');
    }
    expect(AccountCache.value('xhs')?.loggedIn, isTrue);
    expect(LoginExpiredBus.expired.value, isNot(contains('xhs')));
    await AccountCache.clear('xhs');
  });

  test('XHS diagnostic domains require a domain boundary', () {
    expect(xhsDomain('www.rednote.com'), 'rednote.com');
    expect(xhsDomain('www.xiaohongshu.com'), 'xiaohongshu.com');
    expect(xhsDomain('rednote.com.example.org'), isNull);
  });

  test('XHS two-domain session state does not turn unknown into logged out', () {
    expect(combineXhsSessionStates([true, null]), SessionStatus.valid);
    expect(combineXhsSessionStates([false, true]), SessionStatus.valid);
    expect(combineXhsSessionStates([false, false]), SessionStatus.invalid);
    expect(combineXhsSessionStates([false, null]), SessionStatus.unknown);
    expect(combineXhsSessionStates([null, null]), SessionStatus.unknown);
    expect(combineXhsSessionStates([false]), SessionStatus.unknown);
  });

  test('redirect to another domain cannot invalidate the original session', () {
    final target = Uri.parse('https://www.xiaohongshu.com/explore');
    final rednoteLogin = Uri.parse('https://www.rednote.com/login');
    expect(xhsDomainObservation(target, rednoteLogin, false), isNull);
    expect(xhsDomainObservation(target, Uri.parse('https://www.xiaohongshu.com/login'), false), isFalse);
    expect(combineXhsSessionStates([
      xhsDomainObservation(target, rednoteLogin, false),
      false,
    ]), SessionStatus.unknown);
  });
}
