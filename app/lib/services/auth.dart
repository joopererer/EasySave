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

import 'site_registry.dart';
import 'parser_hooks.dart';
import 'update_service.dart';

/// Open site identifiers retain the persisted platform key verbatim.
Iterable<String> get loginSiteIds => SiteRegistry.current.sites
    .where(
      (site) =>
          site.enabled && {'optional', 'required'}.contains(site.auth['mode']),
    )
    .map((site) => site.id);

String platformLabel(String siteId) =>
    SiteRegistry.current.byId(siteId)?.displayName ?? siteId;

String platformFromKey(String key) => key;

/// Map a post URL to the platform that serves it, or null if unsupported.
String? platformFromUrl(String url) {
  final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
  if (host.isEmpty) return null;
  if (host == 'tiktok.com' || host.endsWith('.tiktok.com')) return 'tiktok';
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
    return 'xhs';
  }
  if (host == 'instagram.com' ||
      host.endsWith('.instagram.com') ||
      host.endsWith('.instagr.am')) {
    return 'instagram';
  }
  if (host == 'x.com' ||
      host.endsWith('.x.com') ||
      host.endsWith('twitter.com') ||
      host.endsWith('t.co')) {
    return 'x';
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

String loginEntryUrl(String platform) {
  final url = SiteRegistry.current.byId(platform)?.auth['loginUrl'];
  if (url is! String) throw StateError('No login entry for $platform');
  return url;
}

String? loginUserAgent(String platform) =>
    SiteRegistry.current.byId(platform)?.auth['userAgent'] as String?;

List<String> _cookieUrls(String platform) {
  final auth = SiteRegistry.current.byId(platform)?.auth;
  return (auth?['cookieUrls'] as List?)?.cast<String>() ??
      [loginEntryUrl(platform)];
}

bool _isSessionCookie(String platform, String name) =>
    (SiteRegistry.current.byId(platform)?.auth['sessionCookieNames'] as List? ??
            [])
        .contains(name);

bool hasAccountHook(String platform) =>
    SiteRegistry.current.byId(platform)?.auth['stateHook'] != null;

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

/// True when the persistent cookie store holds a session cookie.
Future<bool> isLoggedIn(String platform) async {
  try {
    final cookieManager = CookieManager.instance();
    final urls = _cookieUrls(platform).map(WebUri.new);

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
  String platform, {
  InAppWebViewController? webViewController,
}) async {
  if (!hasAccountHook(platform)) return isLoggedIn(platform);

  if (webViewController != null) {
    final account = await readAccount(platform, webViewController);
    if (account != null) {
      await AccountCache.save(platform, account);
      return account.loggedIn;
    }
  }

  final cached = await AccountCache.load(platform);
  if (cached != null) return cached.loggedIn;
  // Nothing cached yet (e.g. right after an app update): fall back to the
  // cookie jar plus a cheap network probe, which is accurate but slower.
  return verifyAccountSession(platform);
}

/// Signed-in XHS user, as read from the page itself.
class SiteAccount {
  const SiteAccount({required this.loggedIn, this.userId, this.nickname});

  const SiteAccount.guest() : this(loggedIn: false);

  final bool loggedIn;
  final String? userId;
  final String? nickname;
}

/// Optional signed parser hook; unknown page state never proves a login.
Future<SiteAccount?> readAccount(
  String platform,
  InAppWebViewController controller,
) async {
  try {
    final script = await ParserManager.instance.getActiveScript();
    final site = SiteRegistry.current.byId(platform);
    final hook = site?.auth['stateHook'];
    if (site == null || hook is! String) return null;
    await controller.evaluateJavascript(source: script);
    final value = await ParserHooks(
      script,
      site,
    ).call(controller, hook, loginEntryUrl(platform));
    if (value is! Map) return null;
    if (value['state'] == 'guest') return const SiteAccount.guest();
    if (value['state'] != 'user') return null;
    return SiteAccount(
      loggedIn: true,
      userId: value['userId']?.toString(),
      nickname: value['nickname']?.toString(),
    );
  } catch (_) {
    return null;
  }
}

/// Per-site account cache. The existing xhs preference keys remain readable.
abstract final class AccountCache {
  static final _values = <String, SiteAccount>{};
  static SiteAccount? value(String platform) => _values[platform];
  static Future<SiteAccount?> load(String platform) async {
    if (_values.containsKey(platform)) return _values[platform];
    final prefs = await SharedPreferences.getInstance();
    if (!prefs.containsKey('${platform}LoggedIn')) return null;
    return _values[platform] = SiteAccount(
      loggedIn: prefs.getBool('${platform}LoggedIn') ?? false,
      userId: prefs.getString('${platform}UserId'),
      nickname: prefs.getString('${platform}Nickname'),
    );
  }

  static Future<void> save(String platform, SiteAccount account) async {
    _values[platform] = account;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('${platform}LoggedIn', account.loggedIn);
      for (final entry in {
        'UserId': account.userId,
        'Nickname': account.nickname,
      }.entries) {
        if (entry.value == null) {
          await prefs.remove('$platform${entry.key}');
        } else {
          await prefs.setString('$platform${entry.key}', entry.value!);
        }
      }
    } catch (_) {}
  }

  static Future<void> clear(String platform) =>
      save(platform, const SiteAccount.guest());
}

/// A cookie is a prerequisite; the optional signed probe interprets the feed.
Future<bool> verifyAccountSession(String platform) async {
  if (!await isLoggedIn(platform)) return false;
  HeadlessInAppWebView? view;
  final client = HttpClient();
  client.connectionTimeout = const Duration(seconds: 6);
  try {
    final script = await ParserManager.instance.getActiveScript();
    final site = SiteRegistry.current.byId(platform)!;
    final hook = site.auth['probeHook'];
    if (hook is! String) return true;
    final request = await client.getUrl(Uri.parse(loginEntryUrl(platform)));
    request.followRedirects = false;
    final ua = loginUserAgent(platform);
    if (ua != null) request.headers.set(HttpHeaders.userAgentHeader, ua);
    request.headers.set(
      HttpHeaders.acceptHeader,
      'text/html,application/xhtml+xml',
    );
    request.headers.set(
      HttpHeaders.acceptLanguageHeader,
      'zh-CN,zh;q=0.9,en;q=0.8',
    );
    final cookies = await cookieHeaderFor(_cookieUrls(platform));
    if (cookies.isNotEmpty) {
      request.headers.set(HttpHeaders.cookieHeader, cookies);
    }
    final response = await request.close().timeout(const Duration(seconds: 8));
    final body = await response
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 8));
    final answer = Completer<bool>();
    view = HeadlessInAppWebView(
      initialData: InAppWebViewInitialData(data: '<html></html>'),
      onLoadStop: (controller, _) async {
        try {
          await controller.evaluateJavascript(source: script);
          final value = await ParserHooks(script, site)
              .call(controller, hook, loginEntryUrl(platform), {
                'input': body,
                'statusCode': response.statusCode,
                'location': response.headers.value(HttpHeaders.locationHeader),
              });
          if (!answer.isCompleted) answer.complete(value != false);
        } catch (_) {
          if (!answer.isCompleted) answer.complete(true);
        }
      },
    );
    await view.run();
    return await answer.future.timeout(const Duration(seconds: 8));
  } catch (_) {
    return true;
  } finally {
    client.close(force: true);
    await view?.dispose();
  }
}

/// Expire host and domain cookies within this site's declared login hosts.
Future<void> logout(String platform) async {
  try {
    final manager = CookieManager.instance();
    final site = SiteRegistry.current.byId(platform);
    for (final url in _cookieUrls(platform)) {
      await manager.deleteCookies(url: WebUri(url));
      final host = Uri.parse(url).host;
      final domains = <String?>{null, '.$host'};
      for (final route in (site?.data['match']['routes'] as List? ?? [])) {
        for (final rule in route['hosts'] as List) {
          if (matchesHost(host, rule)) domains.add('.${rule['domain']}');
        }
      }
      for (final name in (site?.auth['sessionCookieNames'] as List? ?? [])) {
        for (final domain in domains) {
          try {
            await manager.deleteCookie(
              url: WebUri(url),
              name: name,
              domain: domain,
            );
          } catch (_) {}
        }
      }
    }
  } catch (_) {}
  await AccountCache.clear(platform);
  LoginExpiredBus.clear(platform);
}

/// Tracks which platforms failed a parse because their stored session was
/// rejected, so the Mine tab can mark exactly those as expired. Also used as
/// a lightweight "login state changed" signal: clearing always notifies.
abstract final class LoginExpiredBus {
  static final ValueNotifier<Set<String>> expired = ValueNotifier<Set<String>>(
    const {},
  );

  static void markExpired(String platform) {
    // A rejected session invalidates the cached page-state answer too.
    if (hasAccountHook(platform)) {
      unawaited(AccountCache.clear(platform));
    }
    if (expired.value.contains(platform)) return;
    expired.value = {...expired.value, platform};
  }

  static void clear(String platform) {
    expired.value = {...expired.value}..remove(platform);
  }

  static void clearAll() {
    expired.value = const {};
  }
}
