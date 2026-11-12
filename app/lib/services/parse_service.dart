// Platform behavior lives in the verified parser bundle and site manifest.
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'shared_preview_cache.dart';
import 'media_request_policy.dart';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;

import '../core/dev_log.dart';
import '../core/models.dart';
import 'auth.dart'
    show
        SessionStatus,
        isLoopbackHost,
        logXhsWebViewCookies,
        selectXhsPostUrl,
        sessionCookieState;
import 'ai_label_log.dart';
import 'history_db.dart';
import 'links.dart';
import 'site_registry.dart';
import 'parser_hooks.dart';
export 'parser_hooks.dart';
import 'update_service.dart';

class ParseFailure implements Exception {
  ParseFailure(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => message.isEmpty ? '解析失败 ($code)' : message;
}

class ParseOutcome {
  ParseOutcome({
    required this.data,
    required this.rawImages,
    this.degraded = false,
  });
  final ParsedPost data;
  final List<RawImageEntry> rawImages;

  /// True when the answer is a placeholder rather than the post's media — e.g.
  /// only the page's OpenGraph cover on a login-gated page. It is shown to the
  /// user but never cached: the next parse (after login) must not reuse it.
  final bool degraded;
}

/// Polling tolerates transient document replacement; parsing supplies the final error.
Future<void> waitForParserState(
  Future<bool> Function() ready, {
  Duration timeout = const Duration(seconds: 6),
  Duration interval = const Duration(milliseconds: 250),
}) async {
  final watch = Stopwatch()..start();
  while (watch.elapsed < timeout) {
    try {
      if (await ready()) return;
    } catch (_) {}
    await Future<void>.delayed(interval);
  }
}

Future<ParsedPost> parsePostUrl(String url) async =>
    (await parsePostOutcome(url)).data;

/// Only a validated host and a fixed path category may be logged.
String _hostPathOf(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) return '-';
  final host = uri.host.toLowerCase();
  if (!RegExp(r'^[a-z0-9.:-]{1,253}$').hasMatch(host)) return '-';
  return 'host=$host path=${parsePathCategory(uri)}';
}

/// Log one result check so a device failure names the check and both sides.
/// Only platforms, ids, types, indices and host+path are ever written.
void _logParseCheck(
  String check,
  SiteDefinition site, {
  String? postId,
  String expected = '',
  String actual = '',
}) {
  final parts = [
    'check=$check',
    'site=${site.id}',
    'post=${postId ?? '-'}',
    if (expected.isNotEmpty) 'expected=$expected',
    if (actual.isNotEmpty) 'actual=$actual',
  ];
  unawaited(DevLog.write('ParseMismatch', parts.join(' ')));
}

/// `strategy` decides who follows a declared short link. v1.9.0 expands
/// xhslink/t.co over plain HTTP but hands TikTok short links to the WebView
/// (its landing hop sets the cookies the reflow route needs); the manifest
/// must keep that split, so only `http` is expanded here.
String _shortLinkStrategy(Map rule) => rule['strategy'] as String? ?? 'http';

/// Apply account-domain policy at every boundary that can load a post page.
Future<String> chooseFinalParseUrl(
  String url,
  SiteDefinition site, {
  String entry = 'app_input',
}) async {
  final uri = Uri.tryParse(url);
  if (site.id != 'xhs' || uri == null || !site.hasHost(uri.host)) return url;
  final id = site.sourceId(uri);
  if (id == null) return url;
  final selected = await selectXhsPostUrl(url, id, entry: entry);
  unawaited(DevLog.write('ParseWebView', 'event=domain source=${safeCacheLabel(entry)} '
      'site=xhs selected=${Uri.parse(selected).host} result=${selected == url ? 'original' : 'alternate'}'));
  return selected;
}

/// Terminal page check for [uri].
///
/// [requestedUri] is the post URL the App asked the page to load. The token
/// rule must look at that URL: xiaohongshu sends a page without `xsec_token` to
/// its own 404 route, which drops the original query string.
ParseFailure? terminalPageFailure(
  SiteDefinition site,
  Uri? uri, {
  Uri? requestedUri,
}) {
  if (uri == null || !site.hasHost(uri.host)) return null;
  final category = terminalPathCategory(uri);
  for (final rule in site.terminalPages) {
    if (rule is! Map || rule['category'] != category) continue;
    // A site can name the query parameters that carry its access token. When
    // the addressed page has none of them, the page being unavailable says
    // nothing about the post: xiaohongshu returns 404 for a link that was not
    // produced by its own share sheet, while the same post opens fine in a
    // browser. Report the missing token instead of "post does not exist".
    final tokens = site.accessTokenParams;
    final altCode = rule['missingTokenCode'];
    final altMessage = rule['missingTokenMessage'];
    final tokenSource = requestedUri ?? uri;
    final hasToken = tokens.any(
      (name) => (tokenSource.queryParameters[name] ?? '').trim().isNotEmpty,
    );
    if (tokens.isNotEmpty &&
        altCode is String &&
        altMessage is String &&
        !hasToken) {
      return ParseFailure(altCode, altMessage);
    }
    return ParseFailure(rule['code'] as String, rule['message'] as String);
  }
  return null;
}

/// Resolve a declared short link, validate the final route, then enter parsing.
/// The load URL keeps tokens; canonicalization is for identity, not navigation.
/// [enter] receives a null canonical URL when the WebView resolves the link.
Future<T> resolveAndEnterParse<T>(
  String url,
  SiteDefinition site,
  Future<T> Function(String loadUrl, String? canonicalUrl) enter, {
  Future<String?> Function(Uri)? readRedirect,
  Duration? timeout,
  String entry = 'app_input',
}) async {
  final uri = Uri.parse(url);
  final rule = site.shortLink(uri);
  if (rule != null && _shortLinkStrategy(rule) != 'http') {
    // WebView strategy: the browser engine follows the short link and the
    // parser hook canonicalizes what it lands on, exactly as in v1.9.0.
    return enter(url, SiteRegistry.current.canonicalUrl(url));
  }
  var resolved = url;
  if (rule != null) {
    final fallback = site.shortLinkFallback(uri, rule) == 'webview';
    try {
      resolved = await resolveShortLink(
        url,
        readRedirect: readRedirect,
        timeout:
            fallback &&
                (timeout == null || timeout > const Duration(seconds: 5))
            ? const Duration(seconds: 5)
            : timeout,
      );
    } on FormatException {
      if (fallback) return enter(url, null);
      _logParseCheck('SHORT_TARGET_REJECTED', site, actual: _hostPathOf(url));
      throw ParseFailure(ParseErrorCode.invalidPage, '短链跳转目标不受支持');
    } on TimeoutException {
      if (fallback) return enter(url, null);
      rethrow;
    } on IOException {
      if (fallback) return enter(url, null);
      rethrow;
    }
    final terminal = terminalPageFailure(site, Uri.tryParse(resolved));
    if (terminal != null) {
      if (fallback && terminal.code != ParseErrorCode.unsupportedUrl) {
        return enter(url, null);
      }
      throw terminal;
    }
    if (resolved == url) {
      if (fallback) return enter(url, null);
      _logParseCheck('SHORT_NOT_EXPANDED', site, actual: _hostPathOf(url));
      throw ParseFailure(ParseErrorCode.invalidPage, '短链未能展开，请重试');
    }
  }
  final target = SiteRegistry.current.match(resolved);
  if (target?.id != site.id) {
    if (rule != null && site.shortLinkFallback(uri, rule) == 'webview') {
      return enter(url, null);
    }
    _logParseCheck(
      'SHORT_TARGET_SITE',
      site,
      expected: site.id,
      actual: target?.id ?? _hostPathOf(resolved),
    );
    throw ParseFailure(ParseErrorCode.invalidPage, '短链跳转目标不受支持');
  }
  final canonical = SiteRegistry.current.canonicalUrl(resolved);
  if (canonical == null) {
    if (rule != null && site.shortLinkFallback(uri, rule) == 'webview') {
      return enter(url, null);
    }
    _logParseCheck(
      'SHORT_TARGET_NOT_POST',
      site,
      actual: _hostPathOf(resolved),
    );
    throw ParseFailure(ParseErrorCode.invalidPage, '短链跳转目标不是作品页面');
  }
  final selected = await chooseFinalParseUrl(resolved, site, entry: entry);
  return enter(selected, canonical);
}

ParseOutcome _decodeSharedOutcome(Map value) => ParseOutcome(
  data: ParsedPost.fromJson(Map<String, dynamic>.from(value['post'] as Map)),
  rawImages: [
    for (final raw in value['rawImages'] as List? ?? const [])
      RawImageEntry(
        keys: (raw['keys'] as List).cast<String>(),
        scenes: [
          for (final scene in raw['scenes'] as List)
            RawScene(
              scene: scene['scene'] as String,
              url: scene['url'] as String,
            ),
        ],
      ),
  ],
);

/// All entry points share this read-through/write-through native RAM store.
class CachedPostParser {
  CachedPostParser({
    required this.parseNetwork,
    this.resolveIdentityUrl,
    this.channel = sharedPreviewChannel,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;
  final Future<ParseOutcome> Function(String url, String entry) parseNetwork;
  final Future<String> Function(String url)? resolveIdentityUrl;
  final MethodChannel channel;
  final DateTime Function() now;
  final _fallback = SharedParseCache<Map<String, dynamic>>();
  final _running = <String, Future<ParseOutcome>>{};

  /// Per-site generation. A login-state change bumps it, so a parse that was
  /// already running cannot publish its pre-change answer afterwards.
  final _generations = <String, int>{};

  String keyFor(String url) {
    final site = SiteRegistry.current.match(url);
    final id = site?.sourceId(Uri.parse(url));
    return id == null ? opaquePreviewKey(url) : '${site!.id}:$id';
  }

  /// Forget every parsed post of [site] in the shared and the local store.
  ///
  /// A login-state change makes the previous answer a guess: the guest parse of
  /// a login-gated post is a cover, and reusing it after login hides the media.
  Future<void> invalidateSite(String site) async {
    _generations[site] = (_generations[site] ?? 0) + 1;
    _fallback.removeWhere((value) => value['site'] == site);
    _running.removeWhere((key, _) => key.startsWith('$site:'));
    try {
      await channel.invokeMethod<void>('clearParsed', {'site': site});
    } on MissingPluginException {
      // The local RAM store is already cleared.
    } on PlatformException {
      // A failed clear cannot be repaired here; the next parse overwrites.
    }
  }

  Future<Map<String, dynamic>?> lookup(String key) async {
    try {
      return await channel.invokeMapMethod<String, dynamic>('lookupParsed', {
        'key': key,
      });
    } on MissingPluginException {
      final value = _fallback.get(key);
      return {'status': value == null ? 'miss' : 'hit', 'value': value};
    } on PlatformException {
      return {'status': 'miss'};
    }
  }

  Future<ParseOutcome> parse(
    String url, {
    String entry = 'app_input',
    bool forceRefresh = false,
    FutureOr<void> Function()? onCacheMiss,
    void Function()? onCacheHit,
  }) {
    final key = keyFor(url);
    // A forced refresh never joins an in-flight task: that task may be about to
    // answer from the cache, which is exactly what "刷新" must not accept.
    final existing = forceRefresh ? null : _running[key];
    if (existing != null) return existing;
    final task = _parse(url, entry: entry, forceRefresh: forceRefresh,
        onCacheMiss: onCacheMiss, onCacheHit: onCacheHit);
    _running[key] = task;
    unawaited(task.then<void>((_) {
      if (identical(_running[key], task)) _running.remove(key);
    }, onError: (Object _, StackTrace __) {
      if (identical(_running[key], task)) _running.remove(key);
    }));
    return task;
  }

  Future<ParseOutcome> _parse(
    String url, {
    required String entry,
    required bool forceRefresh,
    FutureOr<void> Function()? onCacheMiss,
    void Function()? onCacheHit,
  }) async {
    final site = SiteRegistry.current.match(url);
    if (site == null || !site.enabled) return parseNetwork(url, entry);
    final generation = _generations[site.id] ?? 0;
    final originalKey = keyFor(url);
    var key = originalKey;
    var postId = site.sourceId(Uri.parse(url)) ?? '-';
    Future<void> log(String event) => DevLog.write(
      'ParseCache',
      'event=$event entry=${safeCacheLabel(entry)} post=${safeCacheLabel(postId)}',
    );
    if (!forceRefresh) {
      var response = await lookup(key);
      if (response?['status'] == 'miss' &&
          site.sourceId(Uri.parse(url)) == null &&
          resolveIdentityUrl != null) {
        try {
          final resolved = await resolveIdentityUrl!(url);
          if (SiteRegistry.current.match(resolved)?.id == site.id) {
            key = keyFor(resolved);
            postId = site.sourceId(Uri.parse(resolved)) ?? postId;
            if (key != originalKey) response = await lookup(key);
          }
        } catch (_) {
          /* Preserve the existing parser's short-link fallback. */
        }
      }
      // The lookup itself can overlap a login change; its answer is unusable then.
      final value = response?['value'];
      if (value is Map && (_generations[site.id] ?? 0) == generation) {
        try {
          final cached = _decodeSharedOutcome(value);
          postId = cached.data.id;
          if (response?['status'] == 'expired' ||
              (value['expires'] as int) <= now().millisecondsSinceEpoch)
            throw StateError('EXPIRED');
          final policy = MediaRequestPolicy(site);
          for (final item in cached.data.items) {
            for (final resource in policy.resourcesFor(item)) {
              policy.validate(resource);
              if (resource.request.expiresAt != null &&
                  !resource.request.expiresAt!.isAfter(now()))
                throw StateError('EXPIRED');
              final expiry = mediaUrlExpiry(resource.url);
              if (expiry != null && !expiry.isAfter(now()))
                throw StateError('EXPIRED');
            }
          }
          onCacheHit?.call();
          unawaited(log('hit'));
          return cached;
        } catch (_) {
          await log('expired');
        }
      } else if (response?['status'] == 'expired') {
        await log('expired');
      }
    }
    unawaited(log('miss'));
    await onCacheMiss?.call();
    final outcome = await parseNetwork(url, entry);
    postId = outcome.data.id;
    if ((_generations[site.id] ?? 0) != generation) {
      // The login state changed while this page was loading: the answer belongs
      // to the previous session, so it is returned but never published.
      await log('dropped');
      return outcome;
    }
    if (outcome.degraded) {
      // Failures and placeholders are not answers: a cover kept here would be
      // handed out again after the user logs in.
      await log('degraded');
      return outcome;
    }
    final canonical =
        '${SiteRegistry.current.canonicalId(outcome.data.platform)}:$postId';
    final post = outcome.data.toJson();
    // Legacy parser/backup JSON intentionally omits these fields. RAM must not.
    post['items'] = [
      for (final item in outcome.data.items)
        {
          ...item.toJson(),
          'fallbacks': item.fallbacks,
          if (item.requestResources != null)
            'resources': [
              for (final resource in item.requestResources!) resource.toJson(),
            ],
        },
    ];
    final value = <String, dynamic>{
      'canonical': canonical,
      // Which site this answer belongs to, so a login change can drop exactly
      // that site's entries from the shared store.
      'site': site.id,
      'keys': [canonical, key, originalKey, opaquePreviewKey(url)],
      'expires': now().add(const Duration(minutes: 10)).millisecondsSinceEpoch,
      'post': post,
      'rawImages': [
        for (final raw in outcome.rawImages)
          {
            'keys': raw.keys,
            'scenes': [
              for (final scene in raw.scenes)
                {'scene': scene.scene, 'url': scene.url},
            ],
          },
      ],
    };
    _fallback.put(canonical, value, aliases: [key, opaquePreviewKey(url)]);
    try {
      await channel.invokeMethod<void>('putParsed', value);
    } on MissingPluginException {
      /* Local RAM fallback on other hosts. */
    } on PlatformException {
      /* A cache failure does not discard parsed content. */
    }
    await log('store');
    return outcome;
  }
}

final cachedPostParser = CachedPostParser(
  parseNetwork: (url, entry) => _parsePostOutcomeUncached(url, source: entry),
  resolveIdentityUrl: (url) async {
    final site = SiteRegistry.current.match(url);
    final rule = site?.shortLink(Uri.parse(url));
    if (rule == null || rule['strategy'] != 'http') return url;
    return resolveShortLink(url);
  },
);

/// Drop one site's parsed RAM cache because its login state changed.
///
/// Successful login, logout and a detected expired session all invalidate what
/// was parsed before them: the guest answer of a login-gated post is a cover,
/// and the App must not keep serving it once the session is different.
void clearParsedCacheForSite(String platform, {required String reason}) {
  unawaited(
    cachedPostParser.invalidateSite(platform).then<void>(
      (_) => DevLog.write(
        'ParseCache',
        'event=cleared site=${safeCacheLabel(platform)} reason=$reason',
      ),
    ),
  );
}
Future<ParseOutcome> parsePostOutcome(
  String url, {
  String source = 'app_input',
  bool forceRefresh = false,
  FutureOr<void> Function()? onCacheMiss,
  void Function()? onCacheHit,
}) async {
  final outcome = await cachedPostParser.parse(
    url,
    entry: source,
    forceRefresh: forceRefresh,
    onCacheMiss: onCacheMiss,
    onCacheHit: onCacheHit,
  );
  unawaited(SharedThumbnailCache.instance.prefetch(outcome.data));
  return outcome;
}

Future<ParseOutcome> _parsePostOutcomeUncached(
  String url, {
  String source = 'app',
}) async {
  final preSite = SiteRegistry.current.match(url, includeDisabled: true);
  if (preSite == null) {
    throw ParseFailure(ParseErrorCode.unsupportedUrl, '无法识别链接');
  }
  final budget = Duration(milliseconds: preSite.load['timeoutMs'] as int);
  final watch = Stopwatch()..start();
  Duration remaining() => Duration(
    milliseconds: (budget.inMilliseconds - watch.elapsedMilliseconds).clamp(
      1,
      budget.inMilliseconds,
    ),
  );
  // Loading also validates the cached script and activates the matching registry.
  final script = await ParserManager.instance.getActiveScript().timeout(
    budget,
    onTimeout: () {
      DevLog.write(
        'ParseWebView',
        'event=failure source=$source site=${preSite.id} condition=script_timeout code=TIMEOUT',
      );
      throw ParseFailure(ParseErrorCode.timeout, '加载页面超时，请重试');
    },
  );
  final site = SiteRegistry.current.match(url, includeDisabled: true);
  if (site == null) {
    throw ParseFailure(ParseErrorCode.unsupportedUrl, '无法识别链接');
  }
  if (!site.enabled || !ParserManager.instance.isPlatformEnabled(site.id)) {
    throw ParseFailure(
      ParseErrorCode.blocked,
      ParserManager.instance.getMaintenanceNotice(site.id) ?? '解析服务维护中',
    );
  }
  final hooks = ParserHooks(script, site);
  try {
    return await (() async {
      final result = await resolveAndEnterParse(
        url,
        site,
        (loadUrl, _) => _run(hooks, loadUrl, source: source),
        timeout: remaining(),
        entry: source,
      );
      // Diagnostics only: retweets and quote tweets may answer with a payload
      // id that differs from the one in the link (v1.9.0 kept parsing).
      final linkId = site.sourceId(Uri.parse(url));
      if (linkId != null && linkId != result.data.id) {
        _logParseCheck(
          'ID_DIFFERS_LINK',
          site,
          postId: result.data.id,
          expected: linkId,
          actual: result.data.id,
        );
      }
      if (site.shortLink(Uri.parse(url)) != null) {
        try {
          unawaited(HistoryDb.instance().then((db) => db.rememberParsedLink(url, result.data))
              .catchError((Object _) {}));
        } catch (_) {}
      }
      return result;
    })().timeout(
      remaining(),
      onTimeout: () {
        DevLog.write(
          'ParseWebView',
          'event=failure source=$source site=${site.id} condition=budget code=TIMEOUT',
        );
        throw ParseFailure(ParseErrorCode.timeout, '加载页面超时，请重试');
      },
    );
  } on TimeoutException {
    throw ParseFailure(ParseErrorCode.timeout, '加载页面超时，请重试');
  }
}

Future<bool> _loggedIn(
  ParserHooks hooks,
  InAppWebViewController controller,
  String url,
) async {
  final account = await hooks.call(controller, 'account', url);
  if (account is Map && {'user', 'guest'}.contains(account['state'])) {
    return account['state'] == 'user';
  }
  if (hooks.site.id == 'xhs') return false;
  final loginUrl = hooks.site.auth['loginUrl'];
  if (loginUrl is! String) return false;
  final names = (hooks.site.auth['sessionCookieNames'] as List).cast<String>();
  final cookies = await CookieManager.instance().getCookies(
    url: WebUri(loginUrl),
  );
  return cookies.any(
    (c) => names.contains(c.name) && c.value.toString().isNotEmpty,
  );
}

/// Identity comparison happens on normalized values: a module reports the
/// app platform key (`xhs`) while a manifest may carry the spec/export name
/// (`xiaohongshu`), and an id may arrive as a number. v1.9.0 never compared a
/// result id with the link's id, so retweets/quotes whose payload id differs
/// from the URL keep parsing; the difference is only logged.
String? _normalizedPostId(dynamic value) {
  if (value is String) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
  if (value is num && value.isFinite) return value.toInt().toString();
  return null;
}

/// Why an item cannot be requested; no URL or query ever leaves this function.
String _mediaProblem(dynamic item) {
  if (item is! Map) return 'not_object';
  if (!{'image', 'video', 'live'}.contains(item['type'])) return 'type';
  final uri = Uri.tryParse(item['url']?.toString() ?? '');
  if (uri == null) return 'url_unparsable';
  if (!{'http', 'https'}.contains(uri.scheme)) return 'scheme';
  if (uri.host.isEmpty) return 'host';
  if (uri.userInfo.isNotEmpty) return 'userinfo';
  return '';
}

/// Validate module results before creating application records.
ParseOutcome validateParserResult(dynamic value, SiteDefinition site) {
  if (value is! Map) {
    _logParseCheck(
      'RESULT_NOT_OBJECT',
      site,
      expected: 'object',
      actual: value.runtimeType.toString(),
    );
    throw ParseFailure(ParseErrorCode.invalidPage, '解析结果不是对象');
  }
  if (value['ok'] != true) {
    final error = value['error'];
    final code = error is Map
        ? error['code']?.toString() ?? 'INVALID_PAGE'
        : 'INVALID_PAGE';
    _logParseCheck('MODULE_ERROR', site, expected: 'ok', actual: code);
    throw ParseFailure(
      code,
      error is Map ? error['message']?.toString() ?? '解析失败' : '解析失败',
    );
  }
  final data = value['data'];
  if (data is! Map) {
    _logParseCheck(
      'DATA_NOT_OBJECT',
      site,
      expected: 'object',
      actual: value['data'].runtimeType.toString(),
    );
    throw ParseFailure(ParseErrorCode.invalidPage, '解析模块返回不匹配的内容');
  }
  final platform = (data['platform']?.toString() ?? '').trim().toLowerCase();
  final accepted = {site.id.toLowerCase(), site.platform.toLowerCase()};
  if (!accepted.contains(platform)) {
    _logParseCheck(
      'PLATFORM',
      site,
      expected: accepted.join('|'),
      actual: platform.isEmpty ? '-' : platform,
    );
    throw ParseFailure(ParseErrorCode.invalidPage, '解析模块返回不匹配的内容');
  }
  final id = _normalizedPostId(data['id']);
  if (id == null) {
    final raw = data['id'];
    _logParseCheck(
      'POST_ID',
      site,
      expected: 'non-empty string',
      actual: raw == null
          ? 'null'
          : (raw is String ? 'empty_string' : raw.runtimeType.toString()),
    );
    throw ParseFailure(ParseErrorCode.invalidPage, '解析模块返回不匹配的内容');
  }
  final items = data['items'];
  if (items is! List) {
    _logParseCheck(
      'ITEMS_TYPE',
      site,
      postId: id,
      expected: 'list',
      actual: items.runtimeType.toString(),
    );
    throw ParseFailure(ParseErrorCode.invalidPage, '解析模块返回不匹配的内容');
  }
  // An empty list is a real result (a text-only X post); v1.9.0 accepted it
  // and the save entries already explain "该帖子没有可保存的内容".
  for (var index = 0; index < items.length; index++) {
    final problem = _mediaProblem(items[index]);
    if (problem.isEmpty) continue;
    final item = items[index];
    final keys = item is Map
        ? item.keys
              .whereType<String>()
              .where(
                (key) => RegExp(r'^[A-Za-z][A-Za-z0-9_]{0,40}$').hasMatch(key),
              )
              .take(12)
              .join(',')
        : '-';
    final mediaType =
        item is Map &&
            item['type'] is String &&
            RegExp(r'^[A-Za-z]{1,20}$').hasMatch(item['type'] as String)
        ? item['type'] as String
        : item.runtimeType.toString();
    _logParseCheck(
      'ITEM_MEDIA',
      site,
      postId: id,
      expected: 'http(s) media url',
      actual: 'index=$index reason=$problem type=$mediaType keys=$keys',
    );
    throw ParseFailure(ParseErrorCode.invalidPage, '解析模块返回无效媒体');
  }
  final canonical = site.canonical(id);
  // Tokens in the actual load URL must survive; only metadata uses canonical paths.
  final source = Uri.tryParse(data['url']?.toString() ?? '');
  final preserved = <String, String>{};
  for (final key
      in (site.normalization['preserveLoadQuery'] as List).cast<String>()) {
    final value = source?.queryParameters[key];
    if (value != null) preserved[key] = value;
  }
  final normalized = Uri.parse(canonical);
  final postUrl = preserved.isEmpty
      ? canonical
      : normalized
            .replace(
              queryParameters: {...normalized.queryParameters, ...preserved},
            )
            .toString();
  return ParseOutcome(
    data: ParsedPost.fromJson({
      ...data.cast<String, dynamic>(),
      'platform': site.id,
      'id': id,
      'url': postUrl,
    }),
    rawImages: const [],
  );
}

/// What one page load should do after the `navigate` hook answered.
enum NavigateKind {
  /// The page is a landing/redirect page: keep waiting for the next load.
  wait,

  /// The hook named a different URL inside the site: load it once.
  load,

  /// The page is where it should be: start parsing.
  parse,

  /// The hook named something outside the site: a real mismatch.
  invalid,
}

/// Result of [navigateStep]: the kind plus the URL to load for [NavigateKind.load]
/// (or the offending target for [NavigateKind.invalid]).
class NavigateStep {
  const NavigateStep(this.kind, [this.url]);
  final NavigateKind kind;
  final String? url;
}

/// Apply the `navigate` hook answer for one page load.
///
/// Mirrors v1.9.0's `onLoadStop`: when the current address already is a post
/// page the canonical URL compares equal and parsing starts; when it is a
/// landing page (`{wait: true}`, or no answer at all) the load is ignored and
/// the redirect is awaited. An empty answer is therefore "nothing to do", not a
/// format error — which is what used to abort every TikTok retry.
Future<NavigateStep> navigateStep({
  required SiteDefinition site,
  required String currentUrl,
  required bool alreadyNavigated,
  required Future<dynamic> Function() navigate,
  String? requestedUrl,
}) async {
  final uri = Uri.tryParse(currentUrl);
  final terminal = terminalPageFailure(
    site,
    uri,
    requestedUri: requestedUrl == null ? null : Uri.tryParse(requestedUrl),
  );
  if (terminal != null) throw terminal;
  final action = await navigate();
  if (action is Map) {
    if (action['wait'] == true) return const NavigateStep(NavigateKind.wait);
    final next = action['url'];
    if (next is String && next != currentUrl && !alreadyNavigated) {
      final nextUri = Uri.parse(next);
      if (nextUri.scheme != 'https' || !site.hasHost(nextUri.host)) {
        return NavigateStep(NavigateKind.invalid, next);
      }
      return NavigateStep(NavigateKind.load, next);
    }
    return const NavigateStep(NavigateKind.parse);
  }
  if (action == null) {
    final isPostPage =
        uri != null && site.sourceId(uri) != null && site.hasHost(uri.host);
    return NavigateStep(isPostPage ? NavigateKind.parse : NavigateKind.wait);
  }
  return const NavigateStep(NavigateKind.parse);
}

/// Guest answers that a logged-in session may resolve.
const _sessionRetryCodes = {
  ParseErrorCode.loginRequired,
  ParseErrorCode.ageRestricted,
  ParseErrorCode.protectedAccount,
  ParseErrorCode.privateOrUnavailable,
};

/// Session answers that settle the outcome; anything else keeps the guest one.
const _sessionDefinitiveCodes = {
  ParseErrorCode.loginRequired,
  ParseErrorCode.ageNotSet,
  ParseErrorCode.ageRestricted,
  ParseErrorCode.protectedAccount,
  ParseErrorCode.privateOrUnavailable,
};

/// The logged-in entry page for [targetUrl] when a guest JSON answer failed
/// with a code a session may resolve. A site opts in with `load.entryTemplate`;
/// the page runs in the shared cookie store, so the App never handles cookies.
@visibleForTesting
String? sessionEntryUrl(SiteDefinition site, String targetUrl, dynamic guest) {
  final template = site.load['entryTemplate'];
  if (template is! String || guest is! Map || guest['ok'] == true) return null;
  final error = guest['error'];
  if (error is! Map || !_sessionRetryCodes.contains(error['code'])) return null;
  final uri = Uri.tryParse(targetUrl);
  final id = uri == null ? null : site.sourceId(uri);
  if (id == null || !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(id)) return null;
  final entry = Uri.tryParse(template.replaceAll('{id}', id));
  if (entry == null ||
      entry.scheme != 'https' ||
      entry.userInfo.isNotEmpty ||
      !site.hasHost(entry.host)) {
    return null;
  }
  return entry.toString();
}

/// Retry a restricted guest answer through the logged-in entry page. Returns
/// the session outcome, rethrows a definitive session failure, or null to keep
/// the guest answer (not logged in, page gave no post data, timeout).
Future<ParseOutcome?> _sessionEntryRetry(
  ParserHooks hooks,
  String targetUrl,
  dynamic guest, {
  required String source,
}) async {
  final entryUrl = sessionEntryUrl(hooks.site, targetUrl, guest);
  if (entryUrl == null) return null;
  final login = await sessionCookieState(hooks.site, entry: source);
  if (login != SessionStatus.valid) {
    unawaited(DevLog.write('XLogin',
        'event=decision site=${hooks.site.id} source=guest_only status=${login.name}'));
    return null;
  }
  unawaited(DevLog.write('XLogin',
      'event=decision site=${hooks.site.id} source=session_page '
      'guestRequestCookies=none sessionRequestCookies=webview_managed'));
  try {
    return await _run(hooks, entryUrl, source: source, entryPage: true);
  } on ParseFailure catch (e) {
    if (_sessionDefinitiveCodes.contains(e.code)) rethrow;
    return null;
  } catch (_) {
    return null;
  }
}

const _probeTags = {'XProbe', 'XhsStreamProbe'};

String _probeValue(Object? value) {
  if (value == null) return '-';
  if (value is bool) return value ? '1' : '0';
  if (value is num) return value.isFinite ? value.round().toString() : '-';
  if (value is List) return value.map(_probeValue).join('|');
  final text = value.toString();
  return RegExp(r'^[A-Za-z0-9_.:-]{0,48}$').hasMatch(text) ? text : 'x';
}

/// Log lines for a parser `probe` hook value: whitelisted tags, short tokens
/// and field names only, plus at most 40 sanitized tombstone characters.
@visibleForTesting
List<(String, String)> formatParserProbe(dynamic probe) {
  if (probe is! Map || !_probeTags.contains(probe['tag'])) return const [];
  final tag = probe['tag'] as String;
  if (tag == 'XhsStreamProbe') {
    final rawStreams = probe['streams'];
    final streams = rawStreams is List ? rawStreams : const [];
    final rawImages = probe['images'];
    final images = rawImages is List ? rawImages : const [];
    return [
      for (final (index, image) in images.indexed)
        if (image is Map)
          (
            'XhsImageProbe',
            'image=${index + 1}/${images.length} '
                'declared=${_probeValue(image['width'])}x${_probeValue(image['height'])} '
                'fields=${_probeValue(image['fields'])} '
                'scenes=${_probeValue(image['scenes'])} '
                'candidates=${_probeValue(image['candidates'])} '
                'selected=${_probeValue(image['selected'])}',
          ),
      for (final (index, stream) in streams.indexed)
        if (stream is Map)
          (
            tag,
            'candidate=${index + 1}/${streams.length} '
                'bucket=${_probeValue(stream['bucket'])} '
                'streamType=${_probeValue(stream['streamType'])} '
                'codec=${_probeValue(stream['codec'])} '
                'size=${_probeValue(stream['width'])}x${_probeValue(stream['height'])} '
                'bitrate=${_probeValue(stream['bitrate'])} '
                'audio=${_probeValue(stream['audio'])} '
                'audioCodec=${_probeValue(stream['audioCodec'])} '
                'audioChannels=${_probeValue(stream['audioChannels'])} '
                'audioBitrate=${_probeValue(stream['audioBitrate'])} '
                'audioFields=${_probeValue(stream['audioFields'])} '
                'watermarked=${_probeValue(stream['watermarked'])} '
                'selected=${_probeValue(stream['selected'])}',
          ),
    ];
  }
  final tombstone = probe['tombstone'];
  final text = tombstone is String
      ? '"${tombstone.replaceAll(RegExp(r"[^A-Za-z0-9 .,'!?()-]"), '_').substring(0, tombstone.length < 40 ? tombstone.length : 40)}"'
      : '-';
  return [
    (
      tag,
      'source=${_probeValue(probe['source'])} shape=${_probeValue(probe['shape'])} '
          'typename=${_probeValue(probe['typename'])} '
          'wrapped=${_probeValue(probe['wrapped'] ?? false)} '
          'reason=${_probeValue(probe['reason'])} tombstone=$text '
          'fields=${_probeValue(probe['fields'])} '
          'mediaCount=${_probeValue(probe['mediaCount'])}',
    ),
  ];
}

Future<void> _logParserProbe(
  ParserHooks hooks,
  InAppWebViewController controller,
  String url, [
  Map<String, Object?> extra = const {},
]) async {
  try {
    final probe = await hooks.call(controller, 'probe', url, extra);
    for (final (tag, line) in formatParserProbe(probe)) {
      unawaited(DevLog.write(tag, 'site=${hooks.site.id} $line'));
    }
  } catch (_) {
    // Parser modules without a probe hook have nothing to report.
  }
}

/// Read the page's declared OpenGraph cover; empty when the page has none.
const String _ogImageProbe =
    "(() => { const m = document.querySelector('meta[property=\"og:image\"]');"
    " return m && m.content ? m.content : ''; })()";

/// Hold back an answer whose only media is the page's OpenGraph cover.
///
/// A login-gated page that exposes nothing but `og:image` yields a single
/// dimension-less image, which is a placeholder rather than the post's media
/// (a reel would get Instagram's drawn play button). The answer is still
/// returned so the user sees something, but it is marked [ParseOutcome.degraded]
/// and therefore never cached.
Future<ParseOutcome> _dropCoverOnlyAnswer(
  ParserHooks hooks,
  InAppWebViewController controller,
  ParseOutcome outcome,
) async {
  final items = outcome.data.items;
  if (items.length != 1) return outcome;
  final item = items.single;
  if (item.type != 'image' ||
      item.videoUrl != null ||
      item.width != null ||
      item.height != null) {
    return outcome;
  }
  try {
    final cover = await controller.evaluateJavascript(source: _ogImageProbe);
    if (cover is String && cover.isNotEmpty && cover == item.url) {
      unawaited(
        DevLog.write(
          'ParseCache',
          'event=degraded site=${hooks.site.id} '
              'post=${safeCacheLabel(outcome.data.id)} reason=og_cover_only',
        ),
      );
      return ParseOutcome(
        data: outcome.data,
        rawImages: outcome.rawImages,
        degraded: true,
      );
    }
  } catch (_) {
    // No page probe available: treat the answer as an ordinary result.
  }
  return outcome;
}

Future<ParseOutcome> _run(
  ParserHooks hooks,
  String targetUrl, {
  required String source,
  bool entryPage = false,
}) async {
  targetUrl = await chooseFinalParseUrl(targetUrl, hooks.site, entry: source);
  // A logged-in entry page is a WebView page load even for a JSON site.
  final jsonMode = hooks.site.load['mode'] == 'json' && !entryPage;
  final target = Uri.tryParse(targetUrl);
  DevLog.write(
    'ParseWebView',
    'event=start source=$source site=${hooks.site.id} hasQuery=${target?.hasQuery == true ? 1 : 0}${entryPage ? ' entry=session_page' : ''}',
  );
  final loaded = Completer<InAppWebViewController>();
  var navigated = false;
  var loads = 0;
  var mainNavigations = 0;
  var path = parsePathCategory(target);
  var stage = 'load_wait';
  var checkingReady = false;
  HeadlessInAppWebView? view;
  try {
    view = HeadlessInAppWebView(
      initialUrlRequest: jsonMode
          ? null
          : URLRequest(
              url: WebUri(targetUrl.replaceFirst(RegExp(r'^http:'), 'https:')),
            ),
      initialData: jsonMode
          ? InAppWebViewInitialData(data: '<html></html>')
          : null,
      onConsoleMessage: (_, message) => logUnknownAiLabel(message.message),
      initialUserScripts: UnmodifiableListView([
        UserScript(
          source: '${hooks.script};${hooks.expression('install', targetUrl)}',
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
        userAgent: hooks.site.load['userAgent'] as String?,
        mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
        useShouldOverrideUrlLoading: true,
      ),
      onLoadStart: (_, uri) {
        path = parsePathCategory(uri);
        if (hooks.site.id == 'xhs') {
          unawaited(logXhsWebViewCookies(uri));
        }
      },
      onProgressChanged: (controller, progress) async {
        if (hooks.site.id != 'xhs' || progress < 40 || loaded.isCompleted || checkingReady) return;
        checkingReady = true;
        try {
          final current = (await controller.getUrl())?.toString();
          if (current != null && current == await chooseFinalParseUrl(current, hooks.site, entry: source) &&
              hooks.site.sourceId(Uri.parse(current)) != null &&
              await hooks.call(controller, 'ready', current) == true && !loaded.isCompleted) {
            stage = 'document_ready';
            loaded.complete(controller);
          }
        } catch (_) { /* Full load callback remains available. */ }
        finally { checkingReady = false; }
      },
      shouldOverrideUrlLoading: (controller, action) async {
        final uri = action.request.url;
        if (action.isForMainFrame == true) mainNavigations++;
        if (uri == null || isLoopbackHost(uri.host)) {
          return NavigationActionPolicy.CANCEL;
        }
        if (action.isForMainFrame == true) {
          final selected = await chooseFinalParseUrl(
            uri.toString(),
            hooks.site,
            entry: source,
          );
          if (selected != uri.toString()) {
            await controller.loadUrl(
              urlRequest: URLRequest(url: WebUri(selected)),
            );
            return NavigationActionPolicy.CANCEL;
          }
        }
        if (uri.scheme == 'http' && action.isForMainFrame == true) {
          await controller.loadUrl(
            urlRequest: URLRequest(
              url: WebUri.uri(uri.replace(scheme: 'https')),
            ),
          );
        }
        return uri.scheme == 'https'
            ? NavigationActionPolicy.ALLOW
            : NavigationActionPolicy.CANCEL;
      },
      onLoadStop: (controller, uri) async {
        if (loaded.isCompleted) return;
        loads++;
        path = parsePathCategory(uri);
        DevLog.write(
          'ParseWebView',
          'event=loadStop source=$source site=${hooks.site.id} hasQuery=${uri?.hasQuery == true ? 1 : 0} path=$path loads=$loads navigations=$mainNavigations',
        );
        try {
          if (!jsonMode) {
            stage = 'navigate';
            final current = uri?.toString() ?? targetUrl;
            // Android may omit shouldOverrideUrlLoading for redirect navigations.
            final selected = await chooseFinalParseUrl(
              current,
              hooks.site,
              entry: source,
            );
            if (selected != current) {
              await controller.loadUrl(
                urlRequest: URLRequest(url: WebUri(selected)),
              );
              return;
            }
            final step = await navigateStep(
              site: hooks.site,
              currentUrl: current,
              alreadyNavigated: navigated,
              navigate: () => hooks.call(controller, 'navigate', current),
              // The token rule has to look at the post URL the App requested,
              // not at the 404 route the site redirected to.
              requestedUrl: targetUrl,
            );
            DevLog.write(
              'ParseWebView',
              'event=navigate source=$source site=${hooks.site.id} path=$path loads=$loads navigations=$mainNavigations condition=${step.kind.name}',
            );
            switch (step.kind) {
              case NavigateKind.wait:
                stage = 'load_wait';
                return;
              case NavigateKind.load:
                navigated = true;
                final next = await chooseFinalParseUrl(
                  step.url!,
                  hooks.site,
                  entry: source,
                );
                await controller.loadUrl(
                  urlRequest: URLRequest(url: WebUri(next)),
                );
                stage = 'load_wait';
                return;
              case NavigateKind.invalid:
                _logParseCheck(
                  'NAVIGATE',
                  hooks.site,
                  expected: 'https within site',
                  actual: _hostPathOf(step.url ?? ''),
                );
                throw ParseFailure(ParseErrorCode.invalidPage, '解析模块返回无效导航');
              case NavigateKind.parse:
                break;
            }
          }
          loaded.complete(controller);
        } catch (error, stack) {
          if (!loaded.isCompleted) loaded.completeError(error, stack);
        }
      },
      onReceivedError: (controller, request, error) {
        if (request.isForMainFrame == true && !loaded.isCompleted) {
          DevLog.write(
            'ParseWebView',
            'event=mainFrameError source=$source site=${hooks.site.id} type=${error.type}',
          );
          loaded.complete(controller);
        }
      },
      onReceivedHttpError: (controller, request, response) {
        if (request.isForMainFrame == true) {
          DevLog.write(
            'ParseWebView',
            'event=httpError source=$source site=${hooks.site.id} status=${response.statusCode ?? 0}',
          );
        }
      },
    );
    await view.run();
    final controller = await loaded.future.timeout(const Duration(seconds: 12));
    var currentUrl = jsonMode
        ? targetUrl
        : (await controller.getUrl())?.toString() ?? targetUrl;
    dynamic result;
    if (jsonMode) {
      final request = await hooks.call(controller, 'request', targetUrl);
      if (request is! Map || request['url'] is! String) {
        _logParseCheck(
          'REQUEST_SHAPE',
          hooks.site,
          expected: '{url, headers}',
          actual: request is Map ? 'url_missing' : 'not_object',
        );
        throw ParseFailure(ParseErrorCode.invalidPage, '解析模块返回无效请求');
      }
      final endpoint = Uri.parse(hooks.site.load['endpointTemplate'] as String);
      final uri = Uri.parse(request['url'] as String);
      if (uri.scheme != 'https' ||
          uri.host != endpoint.host ||
          uri.userInfo.isNotEmpty) {
        _logParseCheck(
          'REQUEST_HOST',
          hooks.site,
          expected: endpoint.host,
          actual: _hostPathOf(request['url'] as String),
        );
        throw ParseFailure(ParseErrorCode.invalidPage, '解析模块请求超出声明范围');
      }
      final headers = (request['headers'] as Map? ?? {}).cast<String, String>();
      if (headers.keys.any(
        (key) => !{
          'user-agent',
          'accept',
          'accept-language',
          'referer',
        }.contains(key.toLowerCase()),
      )) {
        _logParseCheck(
          'REQUEST_HEADER',
          hooks.site,
          expected: 'user-agent|accept|accept-language|referer',
          actual: headers.keys
              .where(
                (key) => !{
                  'user-agent',
                  'accept',
                  'accept-language',
                  'referer',
                }.contains(key.toLowerCase()),
              )
              .map((key) => key.toLowerCase())
              .join(','),
        );
        throw ParseFailure(ParseErrorCode.invalidPage, '解析模块请求头超出许可范围');
      }
      // The guest request carries no cookies: only the declared headers.
      final response = await http
          .get(uri, headers: headers)
          .timeout(const Duration(seconds: 15));
      final body = utf8.decode(response.bodyBytes);
      result = await hooks.call(controller, 'parse', targetUrl, {
        'input': body,
      });
      await _logParserProbe(hooks, controller, targetUrl, {'input': body});
      stage = 'session';
      final session = await _sessionEntryRetry(
        hooks,
        targetUrl,
        result,
        source: source,
      );
      if (session != null) {
        DevLog.write(
          'ParseWebView',
          'event=success source=$source site=${hooks.site.id} path=$path loads=$loads navigations=$mainNavigations entry=session_page',
        );
        return session;
      }
    } else {
      stage = 'prepare';
      await hooks.call(controller, 'prepare', currentUrl);
      stage = 'ready';
      await waitForParserState(
        () async => await hooks.call(controller, 'ready', currentUrl) == true,
        // A logged-in entry page fetches its post data after the document.
        timeout: Duration(seconds: entryPage ? 15 : 6),
      );
      stage = 'parse';
      result = await hooks.call(controller, 'parsePage', currentUrl);
      await _logParserProbe(hooks, controller, currentUrl);
    }
    if (result is Map && result['ok'] != true && result['error'] is Map) {
      try {
        final loggedIn = await _loggedIn(hooks, controller, currentUrl);
        final error = await hooks.call(controller, 'classify', currentUrl, {
          'error': result['error'],
          'loggedIn': loggedIn,
        });
        result = {...result, 'error': error};
      } catch (_) {}
    }
    stage = 'validate';
    var outcome = validateParserResult(result, hooks.site);
    if (!jsonMode) {
      outcome = await _dropCoverOnlyAnswer(hooks, controller, outcome);
    }
    DevLog.write(
      'ParseWebView',
      'event=success source=$source site=${hooks.site.id} path=$path loads=$loads navigations=$mainNavigations',
    );
    return outcome;
  } catch (error) {
    final code = error is ParseFailure
        ? error.code
        : error is TimeoutException
        ? 'TIMEOUT'
        : 'UNEXPECTED';
    final safeCode = RegExp(r'^[A-Z_]{1,40}$').hasMatch(code) ? code : 'OTHER';
    DevLog.write(
      'ParseWebView',
      'event=failure source=$source site=${hooks.site.id} path=$path domain=${target?.host ?? 'none'} loads=$loads navigations=$mainNavigations condition=$stage code=$safeCode',
    );
    rethrow;
  } finally {
    await view?.dispose();
  }
}
