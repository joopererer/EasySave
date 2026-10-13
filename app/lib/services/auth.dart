// Login-state checks backed by the shared WebView cookie store.
// Cookies persist across restarts, so login survives app relaunches.

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

enum PlatformKind { xhs, instagram }

String platformLabel(PlatformKind platform) =>
    platform == PlatformKind.xhs ? '小红书' : 'Instagram';

String loginEntryUrl(PlatformKind platform) => platform == PlatformKind.xhs
    ? 'https://www.xiaohongshu.com/login'
    : 'https://www.instagram.com/accounts/login/';

/// 小红书移动端 UA 会命中 App 引流落地页（无登录入口），强制桌面 UA
/// 进入桌面站。登录框默认是二维码，下方有"验证码登录/密码登录"切换，
/// 同一台手机上直接选密码或验证码登录即可，无需扫码。
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

/// Clear session cookies for [platform] (logout).
Future<void> logout(PlatformKind platform) async {
  try {
    await CookieManager.instance().deleteCookies(
      url: WebUri(_cookieUrl(platform)),
    );
  } catch (_) {
    // Best effort; the login page can also expire the session.
  }
}

/// Broadcasts LOGIN_REQUIRED parse failures so the Mine tab can show
/// per-platform "login expired" hints.
abstract final class LoginExpiredBus {
  static final ValueNotifier<String?> code = ValueNotifier<String?>(null);

  static void notify(String errorCode) => code.value = errorCode;
}
