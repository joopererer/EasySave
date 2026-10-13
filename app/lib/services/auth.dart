// Login-state checks backed by the shared WebView cookie store.
// Cookies persist across restarts, so login survives app relaunches.

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

enum PlatformKind { xhs, instagram }

String platformLabel(PlatformKind platform) =>
    platform == PlatformKind.xhs ? '小红书' : 'Instagram';

String loginEntryUrl(PlatformKind platform) => platform == PlatformKind.xhs
    ? 'https://www.xiaohongshu.com/explore'
    : 'https://www.instagram.com/accounts/login/';

/// 小红书移动端 UA 会命中 App 引流落地页（无登录入口），强制桌面 UA
/// 进入桌面站：右上角"登录"为二维码，手机 App 扫码即登。
String? loginUserAgent(PlatformKind platform) => platform == PlatformKind.xhs
    ? 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'
    : null;

String _cookieUrl(PlatformKind platform) => platform == PlatformKind.xhs
    ? 'https://www.xiaohongshu.com'
    : 'https://www.instagram.com';

/// Session cookie names that only exist after a real login.
bool _isSessionCookie(PlatformKind platform, String name) {
  if (platform == PlatformKind.xhs) return name == 'web_session';
  return name == 'sessionid';
}

/// True when the persistent cookie store holds a session cookie.
Future<bool> isLoggedIn(PlatformKind platform) async {
  try {
    final cookies = await CookieManager.instance().getCookies(
      url: WebUri(_cookieUrl(platform)),
    );
    return cookies.any((c) => _isSessionCookie(platform, c.name));
  } catch (_) {
    return false;
  }
}
