// Login-state checks backed by the shared WebView cookie store.
// Cookies persist across restarts, so login survives app relaunches.
//
// Cookies alone are not proof of a live session (XHS also hands cookies to
// anonymous visitors), so inside a WebView we read the sign-in state straight
// from the page (`window.__INITIAL_STATE__.user`, the same trick the
// XHS_Downloader_Android reference app uses). That is authoritative and needs
// no network round-trip, which also keeps the "完成" button instant.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum PlatformKind { xhs, instagram, x, tiktok }

String platformLabel(PlatformKind platform) {
  switch (platform) {
    case PlatformKind.xhs:
      return '小红书';
    case PlatformKind.instagram:
      return 'Instagram';
    case PlatformKind.x:
      return 'X';
    case PlatformKind.tiktok:
      return 'TikTok';
  }
}

/// Map a history record's `platform` key back to a [PlatformKind].
PlatformKind platformFromKey(String key) {
  switch (key) {
    case 'tiktok':
      return PlatformKind.tiktok;
    case 'instagram':
      return PlatformKind.instagram;
    case 'x':
      return PlatformKind.x;
    default:
      return PlatformKind.xhs;
  }
}

/// Map a post URL to the platform that serves it, or null if unsupported.
PlatformKind? platformFromUrl(String url) {
  final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
  if (host.isEmpty) return null;
  if (host == 'tiktok.com' || host.endsWith('.tiktok.com')) return PlatformKind.tiktok;
  if (host == 'xiaohongshu.com' ||
      host.endsWith('.xiaohongshu.com') ||
      host == 'rednote.com' ||
      host.endsWith('.rednote.com') ||
      host == 'xhslink.com' ||
      host.endsWith('.xhslink.com') ||
      host == 'xhslink.cn' ||
      host.endsWith('.xhslink.cn') ||
      host == 'xhs.cn' ||
      host.endsWith('.xhs.cn')) {
    return PlatformKind.xhs;
  }
  if (host == 'instagram.com' ||
      host.endsWith('.instagram.com') ||
      host.endsWith('.instagr.am')) {
    return PlatformKind.instagram;
  }
  if (host == 'x.com' ||
      host.endsWith('.x.com') ||
      host.endsWith('twitter.com') ||
      host.endsWith('t.co')) {
    return PlatformKind.x;
  }
  return null;
}

/// True for loopback URLs used by login hand-offs (e.g. XHS's desktop
/// client callback on `127.0.0.1:54345`). Nothing listens for them inside
/// our WebView, so they must be intercepted instead of loaded.
bool isLoopbackHost(String host) {
  final h = host.toLowerCase();
  return h == '127.0.0.1' ||
      h == 'localhost' ||
      h == '0.0.0.0' ||
      h == '::1' ||
      h == '[::1]';
}

String loginEntryUrl(PlatformKind platform) {
  switch (platform) {
    case PlatformKind.xhs:
      return 'https://www.xiaohongshu.com/explore';
    case PlatformKind.instagram:
      return 'https://www.instagram.com/accounts/login/';
    case PlatformKind.x:
      return 'https://x.com/i/flow/login';
    case PlatformKind.tiktok:
      return 'https://www.tiktok.com/login';
  }
}

/// 小红书移动端 UA 会命中 App 引流落地页（无登录入口），所以把 WebView 的
/// UA 改成桌面形态：去掉 `Mobile` / `Version/4.0`，平台段换成 `X11; Linux
/// x86_64`（与 XHS_Downloader_Android 的做法一致）。
/// Instagram 使用标准移动 Chrome UA，去除内嵌 WebView 标识（Version/4.0 / ; wv）。
String? loginUserAgent(PlatformKind platform) {
  switch (platform) {
    case PlatformKind.xhs:
      return 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36';
    case PlatformKind.instagram:
      return 'Mozilla/5.0 (Linux; Android 12; Pixel 6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Mobile Safari/537.36';
    case PlatformKind.x:
    case PlatformKind.tiktok:
      return null;
  }
}

String _cookieUrl(PlatformKind platform) {
  switch (platform) {
    case PlatformKind.xhs:
      return 'https://www.xiaohongshu.com';
    case PlatformKind.instagram:
      return 'https://www.instagram.com';
    case PlatformKind.x:
      return 'https://x.com';
    case PlatformKind.tiktok:
      return 'https://www.tiktok.com';
  }
}

/// Session cookie names that only exist after a real login.
bool _isSessionCookie(PlatformKind platform, String name) {
  if (platform == PlatformKind.xhs) {
    // XHS sets different session cookies depending on login method:
    // - web_session: desktop web login
    // - customer-sso-sid: SSO/mobile login
    // - galaxy_creator_session_id: creator session
    // - login_token: alternative login token
    return const {
      'web_session',
      'customer-sso-sid',
      'galaxy_creator_session_id',
      'login_token',
    }.contains(name);
  }
  if (platform == PlatformKind.instagram) return name == 'sessionid';
  if (platform == PlatformKind.tiktok) return name == 'sessionid' || name == 'sessionid_ss';
  return name == 'auth_token';
}

/// Harvest cookies for [urls] into a single `Cookie:` header value.
Future<String> cookieHeaderFor(List<String> urls) async {
  final cookieManager = CookieManager.instance();
  final map = <String, String>{};
  for (final raw in urls) {
    try {
      final cookies = await cookieManager.getCookies(url: WebUri(raw));
      for (final c in cookies) {
        if (c.name.isNotEmpty && c.value != null) {
          map[c.name] = '${c.value}';
        }
      }
    } catch (_) {
      // Best effort; a missing URL just contributes no cookies.
    }
  }
  return map.entries.map((e) => '${e.key}=${e.value}').join('; ');
}

/// Cookies to send when fetching an XHS page with plain HTTP.
Future<String> xhsCookieHeader([String? pageUrl]) => cookieHeaderFor([
  'https://www.xiaohongshu.com/',
  'https://edith.xiaohongshu.com/',
  if (pageUrl != null && pageUrl.isNotEmpty) pageUrl,
]);

/// True when the persistent cookie store holds a session cookie.
Future<bool> isLoggedIn(PlatformKind platform) async {
  try {
    final cookieManager = CookieManager.instance();
    final urls = platform == PlatformKind.xhs
        ? [
            WebUri('https://www.xiaohongshu.com/'),
            WebUri('https://www.xiaohongshu.com/explore'),
            WebUri('https://edith.xiaohongshu.com/'),
          ]
        : [WebUri(_cookieUrl(platform))];

    for (final u in urls) {
      final cookies = await cookieManager.getCookies(url: u);
      if (cookies.any((c) => _isSessionCookie(platform, c.name))) return true;
    }
    return false;
  } catch (_) {
    return false;
  }
}

/// Cookie presence, or (for XHS) the page state when a logged-in WebView is
/// available, falling back to a cheap network probe.
Future<bool> checkLogin(
  PlatformKind platform, {
  InAppWebViewController? webViewController,
}) async {
  if (platform != PlatformKind.xhs) return isLoggedIn(platform);

  if (webViewController != null) {
    final account = await readXhsAccount(webViewController);
    if (account != null) {
      await XhsAccountCache.save(account);
      return account.loggedIn;
    }
  }

  final cached = await XhsAccountCache.load();
  if (cached != null) return cached.loggedIn;
  // Nothing cached yet (e.g. right after an app update): fall back to the
  // cookie jar plus a cheap network probe, which is accurate but slower.
  return verifyXhsSession();
}

/// Signed-in XHS user, as read from the page itself.
class XhsAccount {
  const XhsAccount({required this.loggedIn, this.userId, this.nickname});

  const XhsAccount.guest() : this(loggedIn: false);

  final bool loggedIn;
  final String? userId;
  final String? nickname;
}

/// Reads `window.__INITIAL_STATE__.user` — the same source the official web
/// app and XHS_Downloader_Android use. Returns null when the page can't tell
/// us (still booting, or not an XHS page at all).
const String xhsAccountScript = r'''
(function () {
  try {
    var unwrap = function (v) { return v && v.__v_isRef ? v.value : v; };
    var state = window.__INITIAL_STATE__;
    var user = state && unwrap(state.user);
    if (!user) return JSON.stringify({ state: 'unknown' });
    var loggedIn = unwrap(user.loggedIn);
    if (typeof loggedIn !== 'boolean') return JSON.stringify({ state: 'unknown' });
    if (!loggedIn) return JSON.stringify({ state: 'guest' });
    var info = unwrap(user.userInfo);
    if (!info || info.guest === true || !info.userId) {
      return JSON.stringify({ state: 'guest' });
    }
    return JSON.stringify({
      state: 'user',
      userId: String(info.userId),
      nickname: info.nickname || ''
    });
  } catch (e) {
    return JSON.stringify({ state: 'unknown' });
  }
})()
''';

/// Read the sign-in state out of a WebView that is on xiaohongshu.com.
Future<XhsAccount?> readXhsAccount(InAppWebViewController controller) async {
  try {
    final raw = await controller.evaluateJavascript(source: xhsAccountScript);
    if (raw is! String) return null;
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return null;
    switch (decoded['state']) {
      case 'guest':
        return const XhsAccount.guest();
      case 'user':
        return XhsAccount(
          loggedIn: true,
          userId: decoded['userId']?.toString(),
          nickname: decoded['nickname']?.toString(),
        );
      default:
        return null;
    }
  } catch (_) {
    return null;
  }
}

/// Last known XHS account, persisted so the Mine tab can answer instantly
/// without touching the network on every launch.
abstract final class XhsAccountCache {
  static const _loggedInKey = 'xhsLoggedIn';
  static const _userIdKey = 'xhsUserId';
  static const _nicknameKey = 'xhsNickname';

  static XhsAccount? _value;

  /// In-memory value, for synchronous UI reads.
  static XhsAccount? get value => _value;

  static Future<XhsAccount?> load() async {
    if (_value != null) return _value;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!prefs.containsKey(_loggedInKey)) return null;
      _value = XhsAccount(
        loggedIn: prefs.getBool(_loggedInKey) ?? false,
        userId: prefs.getString(_userIdKey),
        nickname: prefs.getString(_nicknameKey),
      );
    } catch (_) {
      return null;
    }
    return _value;
  }

  static Future<void> save(XhsAccount account) async {
    _value = account;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_loggedInKey, account.loggedIn);
      if (account.userId == null) {
        await prefs.remove(_userIdKey);
      } else {
        await prefs.setString(_userIdKey, account.userId!);
      }
      if (account.nickname == null) {
        await prefs.remove(_nicknameKey);
      } else {
        await prefs.setString(_nicknameKey, account.nickname!);
      }
    } catch (_) {
      // Cache only; ignore storage errors.
    }
  }

  static Future<void> clear() => save(const XhsAccount.guest());
}

/// Network truth for XHS, used when no WebView is around: guests are
/// redirected from `/explore` to `/login`, so a session that still loads the
/// feed is a live one. Falls back to cookie presence when the network fails.
Future<bool> verifyXhsSession({
  Duration timeout = const Duration(seconds: 8),
}) async {
  if (!await isLoggedIn(PlatformKind.xhs)) return false;
  try {
    return await _probeXhsFeed().timeout(timeout);
  } catch (_) {
    // Offline / timeout: can't prove it's invalid, so trust the cookie.
    return true;
  }
}

Future<bool> _probeXhsFeed() async {
  final cookieHeader = await xhsCookieHeader();
  final client = HttpClient();
  client.connectionTimeout = const Duration(seconds: 6);
  try {
    final request = await client.getUrl(
      Uri.parse('https://www.xiaohongshu.com/explore'),
    );
    request.followRedirects = false;
    request.headers.set(
      HttpHeaders.userAgentHeader,
      loginUserAgent(PlatformKind.xhs)!,
    );
    request.headers.set(HttpHeaders.acceptHeader, 'text/html,application/xhtml+xml');
    request.headers.set(
      HttpHeaders.acceptLanguageHeader,
      'zh-CN,zh;q=0.9,en;q=0.8',
    );
    if (cookieHeader.isNotEmpty) {
      request.headers.set(HttpHeaders.cookieHeader, cookieHeader);
    }
    final response = await request.close();
    final status = response.statusCode;
    if (status >= 300 && status < 400) {
      final location =
          response.headers.value(HttpHeaders.locationHeader) ?? '';
      await response.drain<void>();
      // Bounced to the login page => the session is dead.
      return !location.contains('/login');
    }
    if (status != 200) {
      await response.drain<void>();
      return true;
    }
    final body = await response.transform(utf8.decoder).join();
    if (body.contains('"loggedIn":false')) return false;
    if (body.contains('"loggedIn":true')) return true;
    // Feed served without a login wall: treat as logged in.
    return true;
  } finally {
    client.close(force: true);
  }
}

/// Clear session cookies for [platform] (logout).
Future<void> logout(PlatformKind platform) async {
  try {
    final cookieManager = CookieManager.instance();
    await cookieManager.deleteCookies(url: WebUri(_cookieUrl(platform)));
    if (platform == PlatformKind.xhs) {
      for (final url in const [
        'https://edith.xiaohongshu.com',
        'https://www.xiaohongshu.com/explore',
      ]) {
        await cookieManager.deleteCookies(url: WebUri(url));
      }
      // `web_session` is usually a domain cookie on `.xiaohongshu.com`;
      // deleting by URL alone would leave it behind (it is written host- or
      // domain-scoped depending on the login flow), so expire it both ways.
      for (final name in const [
        'web_session',
        'customer-sso-sid',
        'galaxy_creator_session_id',
        'login_token',
      ]) {
        for (final domain in const [null, '.xiaohongshu.com']) {
          try {
            await cookieManager.deleteCookie(
              url: WebUri('https://www.xiaohongshu.com'),
              name: name,
              domain: domain,
            );
          } catch (_) {
            // Some platforms reject domain-scoped deletes; best effort.
          }
        }
      }
    }
  } catch (_) {
    // Best effort; the login page can also expire the session.
  }
  await XhsAccountCache.clear();
  LoginExpiredBus.clear(platform);
}

/// Tracks which platforms failed a parse because their stored session was
/// rejected, so the Mine tab can mark exactly those as expired. Also used as
/// a lightweight "login state changed" signal: clearing always notifies.
abstract final class LoginExpiredBus {
  static final ValueNotifier<Set<PlatformKind>> expired =
      ValueNotifier<Set<PlatformKind>>(const {});

  static void markExpired(PlatformKind platform) {
    // A rejected session invalidates the cached page-state answer too.
    if (platform == PlatformKind.xhs) {
      unawaited(XhsAccountCache.clear());
    }
    if (expired.value.contains(platform)) return;
    expired.value = {...expired.value, platform};
  }

  static void clear(PlatformKind platform) {
    expired.value = {...expired.value}..remove(platform);
  }

  static void clearAll() {
    expired.value = const {};
  }
}
