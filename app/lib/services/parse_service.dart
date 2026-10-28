// Headless parsing: load a post URL in a real (headless) WebView — which
// follows short links and clears Xiaohongshu's anti-bot the same way a user's
// browser does — inject parser.js and execute EasySaveParser.
// Throws [ParseFailure] so callers can distinguish login walls.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;

import '../core/models.dart';
import '../core/parse.dart';
import 'auth.dart';
import 'ai_label_log.dart';
import 'links.dart';
import 'update_service.dart';
import 'tiktok_links.dart';
import 'history_db.dart';

class ParseFailure implements Exception {
  ParseFailure(this.code, this.message);
  final String code;
  final String message;

  @override
  String toString() => message.isNotEmpty ? message : '解析失败 ($code)';
}

Future<T> _withTimeout<T>(Future<T> Function() run, String what) {
  return run().timeout(
    const Duration(seconds: 20),
    onTimeout: () =>
        throw ParseFailure(ParseErrorCode.timeout, '$what超时（20秒），请重试'),
  );
}

void _checkPlatform(String url) {
  final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
  String platform = '';
  if (isXhsHost(host)) {
    platform = 'xhs';
  } else if (isInstagramHost(host)) {
    platform = 'instagram';
  } else if (isXHost(host)) {
    platform = 'x';
  } else if (isTiktokHost(host)) {
    platform = 'tiktok';
  }

  if (platform.isNotEmpty && !ParserManager.instance.isPlatformEnabled(platform)) {
    final notice = ParserManager.instance.getMaintenanceNotice(platform) ??
        '该平台解析服务维护中，请稍后再试';
    throw ParseFailure(ParseErrorCode.blocked, notice);
  }
}

String? extractTweetId(String url) {
  final match = RegExp(
    r'(?:x|twitter)\.com/(?:[^/]+)/status/(\d+)',
    caseSensitive: false,
  ).firstMatch(url);
  if (match != null) return match.group(1);
  final fallback = RegExp(r'/status/(\d+)').firstMatch(url);
  return fallback?.group(1);
}

String calculateXToken(String id) {
  final numId = double.tryParse(id) ?? 0.0;
  final val = (numId / 1e15) * math.pi;
  final intPart = val.floor();
  var fracPart = val - intPart;
  var res = intPart.toRadixString(36);
  if (fracPart > 0) {
    var fracStr = '';
    for (var i = 0; i < 8; i++) {
      fracPart *= 36;
      var d = fracPart.floor();
      if (i == 7) {
        final remainder = fracPart - d;
        if (remainder >= 0.5) d += 1;
      }
      fracStr += d.toRadixString(36);
      fracPart -= d;
    }
    res += '.$fracStr';
  }
  return res.replaceAll(RegExp(r'(0+|\.)'), '');
}

/// Load [url] and parse the post it resolves to.
Future<ParsedPost> parsePostUrl(String url) {
  return parsePostOutcome(url).then((result) => result.data);
}

/// Same as [parsePostUrl] but keeps the raw image entries for diagnostics.
Future<ParseOutcome> parsePostOutcome(String url) {
  _checkPlatform(url);
  return _withTimeout(() async {
    final resolved = await _resolveForParse(url);
    try {
      final result = await _parseInner(resolved);
      final host = Uri.tryParse(url)?.host.toLowerCase();
      if (result.data.platform == 'tiktok' && {'vm.tiktok.com', 'vt.tiktok.com'}.contains(host)) {
        try {
          await HistoryDb.instance().then((db) => db.rememberParsedLink(url, result.data)).timeout(const Duration(seconds: 2));
        } catch (_) { /* Optional local shortcut must not fail a successful parse. */ }
      }
      return result;
    } on ParseFailure catch (e) {
      throw await _reclassifyFailure(resolved, e);
    }
  }, '加载页面');
}

/// App-side reclassification: when a platform we are NOT logged into reports
/// PRIVATE_OR_UNAVAILABLE, the real cause is usually "needs login" (e.g. XHS
/// serves a login-gated note as unavailable). The parser and spec/fixtures are
/// untouched — this only re-labels the error for the user. Applies to every
/// parse path, including the background engine.
Future<ParseFailure> _reclassifyFailure(String url, ParseFailure e) async {
  final platform = platformFromUrl(url);
  if (platform == null) return e;

  if (e.code == ParseErrorCode.privateOrUnavailable) {
    try {
      if (!await isLoggedIn(platform)) {
        return ParseFailure(
          ParseErrorCode.loginRequired,
          '可能需要登录${platformLabel(platform)}',
        );
      }
    } catch (_) {
      // Fall through to the original failure.
    }
  } else if (e.code == ParseErrorCode.loginRequired && platform == PlatformKind.instagram) {
    try {
      if (await isLoggedIn(platform)) {
        // User has a valid session cookie, but post media was unavailable or restricted.
        // Reclassify so we don't falsely expire their active session.
        return ParseFailure(
          ParseErrorCode.privateOrUnavailable,
          e.message.contains('敏感内容') || e.message.contains('年龄限制')
              ? e.message
              : '未能读取帖子内容（可能包含受限内容或已被删除）',
        );
      }
    } catch (_) {}
  }
  return e;
}

/// Resolve short links to their final URL, except for Xiaohongshu.
///
/// XHS's anti-bot bounces plain-HTTP clients (even with a mobile UA) to
/// /login, so HTTP resolution throws away the real note URL and its
/// `xsec_token`. For XHS we hand the short link to the WebView untouched —
/// a real browser engine follows the redirect to the actual note page.
/// Resolve short links to their final URL.
Future<String> _resolveForParse(String url) async {
  if (isTiktokLink(url)) return canonicalTiktokUrl(url) ?? url;
  try {
    return await resolveShortLink(
      url,
    ).timeout(const Duration(seconds: 10), onTimeout: () => url);
  } catch (_) {
    return url;
  }
}

class ParseOutcome {
  ParseOutcome({required this.data, required this.rawImages});

  final ParsedPost data;
  final List<RawImageEntry> rawImages;
}



/// Poll the page until `__INITIAL_STATE__` carries this note, instead of
/// guessing with a fixed delay. Gives up quietly so the parser can still
/// produce a proper error afterwards.
Future<void> _waitForNoteState(
  InAppWebViewController controller,
  String targetUrl, {
  Duration timeout = const Duration(seconds: 6),
}) async {
  final noteId = RegExp(
    r'/([a-f0-9]{24})',
    caseSensitive: false,
  ).firstMatch(targetUrl)?.group(1);
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    try {
      final ready = await controller.evaluateJavascript(
        source: '''
(() => {
  try {
    const state = window.__INITIAL_STATE__;
    if (!state) return false;
    const wanted = ${jsonEncode(noteId)};
    if (state.note && state.note.noteDetailMap) {
      const map = state.note.noteDetailMap;
      if (!wanted) return Object.keys(map).length > 0;
      return Object.prototype.hasOwnProperty.call(map, wanted);
    }
    if (state.noteData && state.noteData.data) {
      const note = state.noteData.data.noteData || state.noteData.data;
      if (note) {
        if (!wanted) return true;
        const id = note.noteId || note.id;
        return !id || id === wanted;
      }
    }
    return false;
  } catch (_) {
    return false;
  }
})()
''',
      );
      if (ready == true) return;
    } catch (_) {
      // Controller may not be ready yet; keep polling until the deadline.
    }
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }
}

Future<ParseOutcome> _runParserJs(String input, String pageUrl) async {
  final loaded = Completer<void>();
  InAppWebViewController? readyController;
  HeadlessInAppWebView? headless;
  try {
    headless = HeadlessInAppWebView(
      initialData: InAppWebViewInitialData(data: '<html><body></body></html>'),
      onConsoleMessage: (_, message) => logUnknownAiLabel(message.message),
      onLoadStop: (controller, uri) {
        readyController ??= controller;
        if (!loaded.isCompleted) loaded.complete();
      },
      onReceivedError: (controller, request, error) {
        readyController ??= controller;
        if (!loaded.isCompleted) loaded.complete();
      },
    );
    await headless.run();
    await loaded.future.timeout(const Duration(seconds: 5));
    final controller = readyController ?? headless.webViewController;
    if (controller == null) {
      throw ParseFailure(ParseErrorCode.invalidPage, 'JS 引擎未能初始化');
    }

    final parserJs = await ParserManager.instance.getActiveScript();
    await controller.evaluateJavascript(source: parserJs);
    final jsResult = await controller.evaluateJavascript(
      source:
          'EasySaveParser.parse(${jsonEncode(input)}, ${jsonEncode(pageUrl)})',
    );

    if (jsResult == null) {
      throw ParseFailure(ParseErrorCode.invalidPage, '解析结果为空');
    }

    Map<String, dynamic> resultJson;
    try {
      if (jsResult is String) {
        resultJson = (jsonDecode(jsResult) as Map).cast<String, dynamic>();
      } else if (jsResult is Map) {
        resultJson = jsResult.cast<String, dynamic>();
      } else {
        throw ParseFailure(ParseErrorCode.invalidPage, '解析器返回非 JSON 结果');
      }
    } catch (e) {
      if (e is ParseFailure) rethrow;
      throw ParseFailure(ParseErrorCode.invalidPage, '解析器结果格式错误: $e');
    }

    final ok = resultJson['ok'] == true;
    if (!ok) {
      final error = resultJson['error'] as Map?;
      final code = error?['code']?.toString() ?? ParseErrorCode.invalidPage;
      final message = error?['message']?.toString() ?? '解析失败';
      throw ParseFailure(code, message);
    }

    final dataMap = resultJson['data'] as Map?;
    if (dataMap == null) {
      throw ParseFailure(ParseErrorCode.invalidPage, '解析结果中没有数据');
    }

    final post = ParsedPost.fromJson(dataMap.cast<String, dynamic>());
    return ParseOutcome(data: post, rawImages: const []);
  } finally {
    await headless?.dispose();
  }
}

Future<ParseOutcome> _parseXPost(String url) async {
  final tweetId = extractTweetId(url);
  if (tweetId == null) {
    throw ParseFailure(ParseErrorCode.unsupportedUrl, '无法识别推文链接: $url');
  }

  final token = calculateXToken(tweetId);
  final endpointTpl = ParserManager.instance.getPlatformEndpoint('x');
  final endpointUrl = endpointTpl
      .replaceAll('{id}', tweetId)
      .replaceAll('{token}', token);

  final headers = ParserManager.instance.getPlatformHeaders('x') ??
      const {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36',
      };

  http.Response response;
  try {
    response = await http
        .get(Uri.parse(endpointUrl), headers: headers)
        .timeout(const Duration(seconds: 15));
  } catch (e) {
    throw ParseFailure(ParseErrorCode.timeout, '请求 X 接口超时，请重试');
  }

  if (response.statusCode == 404) {
    throw ParseFailure(ParseErrorCode.privateOrUnavailable, '该帖子不存在、私密或已删除');
  }

  final jsonStr = utf8.decode(response.bodyBytes);
  return _runParserJs(jsonStr, url);
}

Future<ParseOutcome> _parseInner(String url) async {
  // Remote platform switch check: do not start WebView or make requests if disabled
  _checkPlatform(url);

  final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
  if (isXHost(host)) {
    return _parseXPost(url);
  }

  var targetUrl = url;
  final isXhs = isXhsHost(host);
  if (isXhs) {
    if (targetUrl.startsWith('http://')) {
      targetUrl = targetUrl.replaceFirst('http://', 'https://');
    }
    // Do NOT rewrite the URL: `xsec_token` is bound to the exact path the
    // share link points at (usually /discovery/item/...), and a short link
    // (xhslink) must be followed by a real browser engine. Rewriting to
    // /explore/<id>, decoding %3D, or HTTP-resolving all break the token.
    //
    // XHS always goes through the WebView: its anti-bot 302s *any* plain
    // HTTP client (valid token or not) to /login or a captcha wall, so the
    // HTTP fast path can never succeed here and only adds latency. A real
    // browser engine follows short links and keeps the token, exactly like
    // the user's own browser (verified: xhslink -> /explore/<id>?xsec_token=...).
    return _parseXhsViaWebView(targetUrl);
  }

  return _headlessParse(targetUrl, isXhs: false);
}

/// Loads the note in a real WebView and reads `__INITIAL_STATE__`. This is
/// what XHS_Downloader_Android does, and it mirrors exactly what the user sees
/// in their own browser, so `xsec_token` handling and anti-bot behave the same.
Future<ParseOutcome> _parseXhsViaWebView(String targetUrl) async {
  try {
    return await _headlessParse(targetUrl, isXhs: true);
  } on ParseFailure catch (e) {
    if (e.code != ParseErrorCode.loginRequired &&
        e.code != ParseErrorCode.invalidPage) {
      rethrow;
    }
    // The generic parser failed. Ask the page itself why: a guest session and
    // a dead share link look identical in the parser output but need very
    // different messages and actions. `_headlessParse` already ran
    // `_waitForNoteState`, so a stale `loginRequired` here means the note
    // genuinely wasn't served.
    final loggedIn = await checkLogin(PlatformKind.xhs);
    throw ParseFailure(
      loggedIn
          ? ParseErrorCode.privateOrUnavailable
          : ParseErrorCode.loginRequired,
      loggedIn
          ? '未能读取笔记内容（分享链接可能已过期，请重新粘贴原分享链接再试）'
          : '需要先登录小红书才能解析该笔记',
    );
  }
}

const String _kNetworkSniffScript = '''
(() => {
  if (window.__easysaveSniffInstalled) return;
  window.__easysaveSniffInstalled = true;
  window.__easysaveIgProducts = window.__easysaveIgProducts || {};

  function isProductShaped(obj) {
    if (!obj || typeof obj !== 'object') return false;
    const sc = typeof obj.shortcode === 'string' ? obj.shortcode : (typeof obj.code === 'string' ? obj.code : null);
    if (!sc) return false;
    return ('video_versions' in obj || 'carousel_media' in obj || 'image_versions2' in obj || 'display_url' in obj || 'video_url' in obj || 'edge_sidecar_to_children' in obj);
  }

  function extractProducts(payload) {
    const seen = new Set();
    function visit(node) {
      if (!node || typeof node !== 'object') return;
      if (seen.has(node)) return;
      seen.add(node);
      if (isProductShaped(node)) {
        const sc = typeof node.shortcode === 'string' ? node.shortcode : node.code;
        window.__easysaveIgProducts[sc] = node;
      }
      if (Array.isArray(node)) {
        for (const item of node) visit(item);
      } else {
        for (const key of Object.keys(node)) visit(node[key]);
      }
    }
    try { visit(payload); } catch (_) {}
  }

  function sniffText(text) {
    if (!text || text.length < 10) return;
    if (!text.includes('shortcode') && !text.includes('xdt_shortcode_media') && !text.includes('edge_sidecar_to_children') && !text.includes('display_url')) return;
    try {
      const json = JSON.parse(text);
      extractProducts(json);
    } catch (_) {}
  }

  try {
    const originalFetch = window.fetch;
    if (originalFetch) {
      window.fetch = async function(...args) {
        const response = await originalFetch.apply(this, args);
        try {
          const clone = response.clone();
          clone.text().then(sniffText).catch(() => {});
        } catch (_) {}
        return response;
      };
    }
  } catch (_) {}

  try {
    const originalOpen = XMLHttpRequest.prototype.open;
    const originalSend = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.open = function(method, url, ...rest) {
      this.__url = url;
      return originalOpen.apply(this, [method, url, ...rest]);
    };
    XMLHttpRequest.prototype.send = function(...args) {
      this.addEventListener('load', function() {
        try {
          sniffText(this.responseText);
        } catch (_) {}
      });
      return originalSend.apply(this, args);
    };
  } catch (_) {}
})();
''';

Future<ParseOutcome> _headlessParse(String targetUrl, {required bool isXhs}) async {
  final loaded = Completer<void>();
  final isTiktok = isTiktokLink(targetUrl);
  var canonicalNavigationStarted = false;
  InAppWebViewController? readyController;
  HeadlessInAppWebView? headless;
  try {
    headless = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: WebUri.uri(Uri.parse(targetUrl))),
      onConsoleMessage: (_, message) => logUnknownAiLabel(message.message),
      initialUserScripts: UnmodifiableListView<UserScript>([
        UserScript(
          source: _kNetworkSniffScript,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
      ]),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        domStorageEnabled: true,
        databaseEnabled: true,
        thirdPartyCookiesEnabled: true,
        sharedCookiesEnabled: true,
        cacheEnabled: true,
        mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
        userAgent: isTiktok ? tiktokParserUserAgent : isXhs
            ? loginUserAgent(PlatformKind.xhs)
            : (isInstagramHost(Uri.tryParse(targetUrl)?.host ?? '')
                ? loginUserAgent(PlatformKind.instagram)
                : null),
      ),
      // XHS pages auto-navigate to xhsdiscover:// (app-open scheme) after
      // load, and probe 127.0.0.1 to detect its desktop client. Cancel every
      // non-http(s) navigation and every loopback target (main frame and
      // subframes) so the WebView stays on the note page, whose DOM/state
      // holds the data we parse.
      shouldOverrideUrlLoading: (controller, navigationAction) async {
        final uri = navigationAction.request.url;
        if (uri != null && isLoopbackHost(uri.host)) {
          return NavigationActionPolicy.CANCEL;
        }
        final scheme = uri?.scheme.toLowerCase() ?? '';
        if (scheme == 'http') {
          // Only upgrade main-frame navigations; rewriting subframe URLs can
          // send the WebView into a reload loop.
          if (navigationAction.isForMainFrame == true) {
            final httpsUri = uri!.replace(scheme: 'https');
            controller.loadUrl(
              urlRequest: URLRequest(url: WebUri.uri(httpsUri)),
            );
          }
          return NavigationActionPolicy.CANCEL;
        }
        if (scheme == 'https') {
          return NavigationActionPolicy.ALLOW;
        }
        return NavigationActionPolicy.CANCEL;
      },
      onLoadStop: (controller, uri) async {
        if (isTiktok && !loaded.isCompleted) {
          final canonical = canonicalTiktokUrl(uri?.toString() ?? '');
          if (canonical == null) return;
          if (!canonicalNavigationStarted && targetUrl != canonical) {
            canonicalNavigationStarted = true;
            await controller.loadUrl(urlRequest: URLRequest(url: WebUri(canonical)));
            return;
          }
        }
        readyController ??= controller;
        if (!loaded.isCompleted) loaded.complete();
      },
      onReceivedError: (controller, request, error) {
        // Subresource failures (e.g. the 127.0.0.1 desktop-client probe)
        // say nothing about the main document.
        if (request.isForMainFrame != true) return;
        readyController ??= controller;
        if (!loaded.isCompleted) loaded.complete();
      },
    );
    await headless.run();
    await loaded.future.timeout(const Duration(seconds: 12));
    final controller = readyController ?? headless.webViewController;
    if (controller == null) {
      throw ParseFailure('INVALID_PAGE', '页面未能加载');
    }
    // The note data lives in `__INITIAL_STATE__`, which the SPA fills in after
    // fetch. A fixed sleep is a coin flip on slow networks, so poll instead.
    // Resolve the *real* URL first: a short link has no note id, and following
    // it in the WebView lands us on the tokenized note page.
    String currentUrl = targetUrl;
    try {
      final live = await controller.getUrl();
      final liveStr = live?.toString();
      if (liveStr != null && liveStr.isNotEmpty) currentUrl = liveStr;
    } catch (_) {}
    if (isTiktok) {
      await waitForTiktokState(() async =>
        await controller.evaluateJavascript(source: tiktokStateReadyScript) == true);
    } else {
      await _waitForNoteState(controller, currentUrl);
    }

    // For Instagram: auto-dismiss age-gated / sensitive content warnings if present
    final isIg = isInstagramHost(Uri.tryParse(currentUrl)?.host ?? '');
    if (isIg) {
      try {
        final clicked = await controller.evaluateJavascript(source: '''
(() => {
  const keywords = ['see post', 'view post', '查看帖子', '查看貼文', '了解详情', 'continue', 'i understand', '确认'];
  const buttons = document.querySelectorAll('button, [role="button"], a[role="button"]');
  for (const b of buttons) {
    const text = (b.innerText || b.textContent || '').trim().toLowerCase();
    if (keywords.some(k => text.includes(k))) {
      b.click();
      return true;
    }
  }
  return false;
})()
''');
        if (clicked == true) {
          final shortcodeMatch = RegExp(r'/(?:p|reels?|tv)/([A-Za-z0-9-_]+)').firstMatch(currentUrl);
          final shortcode = shortcodeMatch?.group(1);
          if (shortcode != null) {
            final deadline = DateTime.now().add(const Duration(seconds: 3));
            while (DateTime.now().isBefore(deadline)) {
              final hasProduct = await controller.evaluateJavascript(
                source: '!!((window.__easysaveIgProducts || {})[${jsonEncode(shortcode)}])',
              );
              if (hasProduct == true) break;
              await Future<void>.delayed(const Duration(milliseconds: 300));
            }
          }
        }
      } catch (_) {}
    }

    final parserJs = await ParserManager.instance.getActiveScript();
    dynamic jsResult;
    try {
      await controller.evaluateJavascript(source: parserJs);
      final pageUrlJson = jsonEncode(currentUrl);
      jsResult = await controller.evaluateJavascript(
        source: '''
(() => {
  try {
    const res = JSON.parse(EasySaveParser.parsePage());
    if (res && res.ok) return JSON.stringify(res);
  } catch (_) {}
  try {
    return EasySaveParser.parse(document.documentElement.outerHTML, $pageUrlJson);
  } catch (e) {
    return JSON.stringify({ ok: false, error: { code: 'INVALID_PAGE', message: String(e) } });
  }
})()
''',
      );
    } catch (e) {
      throw ParseFailure(ParseErrorCode.invalidPage, 'JS 执行异常: $e');
    }

    if (jsResult == null) {
      throw ParseFailure(ParseErrorCode.invalidPage, '解析结果为空');
    }

    Map<String, dynamic> resultJson;
    try {
      if (jsResult is String) {
        resultJson = (jsonDecode(jsResult) as Map).cast<String, dynamic>();
      } else if (jsResult is Map) {
        resultJson = jsResult.cast<String, dynamic>();
      } else {
        throw ParseFailure(ParseErrorCode.invalidPage, '解析器返回非 JSON 结果');
      }
    } catch (e) {
      if (e is ParseFailure) rethrow;
      throw ParseFailure(ParseErrorCode.invalidPage, '解析器结果格式错误: $e');
    }

    final ok = resultJson['ok'] == true;
    if (!ok) {
      final error = resultJson['error'] as Map?;
      final code =
          error?['code']?.toString() ?? ParseErrorCode.invalidPage;
      final message = error?['message']?.toString() ?? '解析失败';
      throw ParseFailure(code, message);
    }

    final dataMap = resultJson['data'] as Map?;
    if (dataMap == null) {
      throw ParseFailure(ParseErrorCode.invalidPage, '解析结果中没有数据');
    }

    final post = ParsedPost.fromJson(dataMap.cast<String, dynamic>());
    return ParseOutcome(data: post, rawImages: const []);
  } finally {
    await headless?.dispose();
  }
}
