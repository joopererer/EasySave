import 'package:easysave/services/auth.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';

class _VisitorPlatform extends InAppWebViewPlatform {
  @override
  PlatformCookieManager createPlatformCookieManager(
    PlatformCookieManagerCreationParams params,
  ) => _VisitorCookies(params);
}

class _VisitorCookies extends PlatformCookieManager {
  _VisitorCookies(super.params) : super.implementation();

  @override
  Future<List<Cookie>> getCookies({
    required WebUri url,
    PlatformInAppWebViewController? iosBelow11WebViewController,
    PlatformInAppWebViewController? webViewController,
  }) async => [Cookie(name: 'web_session', value: 'synthetic-guest')];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'guest web_session is never login proof when page-state hook is unavailable',
    () async {
      final previous = InAppWebViewPlatform.instance;
      InAppWebViewPlatform.instance = _VisitorPlatform();
      final site = Map<String, dynamic>.from(
        SiteRegistry.current.byId('xhs')!.data,
      );
      site['auth'] = Map<String, dynamic>.from(site['auth'] as Map)
        ..remove('stateHook');
      SiteRegistry.activate([site]);
      try {
        expect(await isLoggedIn('xhs'), isTrue);
        expect(await checkLogin('xhs'), isFalse);
      } finally {
        SiteRegistry.useBuiltin();
        if (previous != null) InAppWebViewPlatform.instance = previous;
      }
    },
  );
}
