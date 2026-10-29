// Platform behavior lives in the verified parser bundle and site manifest.
import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;

import '../core/models.dart';
import 'auth.dart' show isLoopbackHost;
import 'ai_label_log.dart';
import 'history_db.dart';
import 'links.dart';
import 'site_registry.dart';
import 'update_service.dart';

class ParseFailure implements Exception {
  ParseFailure(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => message.isEmpty ? '解析失败 ($code)' : message;
}

class ParseOutcome {
  ParseOutcome({required this.data, required this.rawImages});
  final ParsedPost data;
  final List<RawImageEntry> rawImages;
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

/// A parse holds one verified script and matching site definition throughout.
class ParserHooks {
  ParserHooks(this.script, this.site);
  final String script;
  final SiteDefinition site;

  String expression(
    String hook,
    String url, [
    Map<String, dynamic> extra = const {},
  ]) =>
      'EasySaveParser.moduleCall(${jsonEncode(site.parserModule)},${jsonEncode(hook)},${jsonEncode({'url': url, 'site': site.data, ...extra})})';

  Future<dynamic> call(
    InAppWebViewController controller,
    String hook,
    String url, [
    Map<String, dynamic> extra = const {},
  ]) async {
    final value = await controller.evaluateJavascript(
      source: expression(hook, url, extra),
    );
    final decoded = value is String ? jsonDecode(value) : value;
    if (decoded is! Map || !decoded.containsKey('value')) {
      throw ParseFailure(ParseErrorCode.invalidPage, '解析模块返回无效结果');
    }
    return decoded['value'];
  }
}

Future<ParsedPost> parsePostUrl(String url) async =>
    (await parsePostOutcome(url)).data;

Future<ParseOutcome> parsePostOutcome(String url) async {
  // Loading also validates the cached script and activates the matching registry.
  final script = await ParserManager.instance.getActiveScript();
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
      final resolved = await resolveShortLink(
        url,
      ).timeout(const Duration(seconds: 10), onTimeout: () => url);
      final result = await _run(hooks, resolved);
      if (site.shortLink(Uri.parse(url)) != null) {
        try {
          await (await HistoryDb.instance())
              .rememberParsedLink(url, result.data)
              .timeout(const Duration(seconds: 2));
        } catch (_) {}
      }
      return result;
    })().timeout(
      Duration(milliseconds: site.load['timeoutMs'] as int),
      onTimeout: () => throw ParseFailure(ParseErrorCode.timeout, '加载页面超时，请重试'),
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

/// Validate module results before creating application records.
ParseOutcome validateParserResult(dynamic value, SiteDefinition site) {
  if (value is! Map) throw ParseFailure(ParseErrorCode.invalidPage, '解析结果不是对象');
  if (value['ok'] != true) {
    final error = value['error'];
    throw ParseFailure(
      error is Map
          ? error['code']?.toString() ?? 'INVALID_PAGE'
          : 'INVALID_PAGE',
      error is Map ? error['message']?.toString() ?? '解析失败' : '解析失败',
    );
  }
  final data = value['data'];
  if (data is! Map ||
      data['platform'] != site.platform ||
      data['id'] is! String ||
      (data['id'] as String).isEmpty ||
      data['items'] is! List ||
      (data['items'] as List).isEmpty) {
    throw ParseFailure(ParseErrorCode.invalidPage, '解析模块返回不匹配的内容');
  }
  final canonical = site.canonical(data['id'] as String);
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
  bool validMedia(dynamic item) {
    if (item is! Map || !{'image', 'video'}.contains(item['type'])) {
      return false;
    }
    final uri = Uri.tryParse(item['url']?.toString() ?? '');
    return uri != null &&
        {'http', 'https'}.contains(uri.scheme) &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty;
  }

  if (!(data['items'] as List).every(validMedia)) {
    throw ParseFailure(ParseErrorCode.invalidPage, '解析模块返回无效媒体');
  }
  return ParseOutcome(
    data: ParsedPost.fromJson({
      ...data.cast<String, dynamic>(),
      'url': postUrl,
    }),
    rawImages: const [],
  );
}

Future<ParseOutcome> _run(ParserHooks hooks, String targetUrl) async {
  final jsonMode = hooks.site.load['mode'] == 'json';
  final loaded = Completer<InAppWebViewController>();
  var navigated = false;
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
      shouldOverrideUrlLoading: (controller, action) async {
        final uri = action.request.url;
        if (uri == null || isLoopbackHost(uri.host)) {
          return NavigationActionPolicy.CANCEL;
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
        try {
          if (!jsonMode) {
            final action = await hooks.call(
              controller,
              'navigate',
              uri?.toString() ?? targetUrl,
            );
            if (action is Map) {
              if (action['wait'] == true) return;
              final next = action['url'];
              if (next is String && next != uri?.toString() && !navigated) {
                final nextUri = Uri.parse(next);
                if (nextUri.scheme != 'https' ||
                    !hooks.site.hasHost(nextUri.host)) {
                  throw ParseFailure(ParseErrorCode.invalidPage, '解析模块返回无效导航');
                }
                navigated = true;
                await controller.loadUrl(
                  urlRequest: URLRequest(url: WebUri(next)),
                );
                return;
              }
            }
          }
          loaded.complete(controller);
        } catch (error, stack) {
          if (!loaded.isCompleted) loaded.completeError(error, stack);
        }
      },
      onReceivedError: (controller, request, error) {
        if (request.isForMainFrame == true && !loaded.isCompleted) {
          loaded.complete(controller);
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
        throw ParseFailure(ParseErrorCode.invalidPage, '解析模块返回无效请求');
      }
      final endpoint = Uri.parse(hooks.site.load['endpointTemplate'] as String);
      final uri = Uri.parse(request['url'] as String);
      if (uri.scheme != 'https' ||
          uri.host != endpoint.host ||
          uri.userInfo.isNotEmpty) {
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
        throw ParseFailure(ParseErrorCode.invalidPage, '解析模块请求头超出许可范围');
      }
      final response = await http
          .get(uri, headers: headers)
          .timeout(const Duration(seconds: 15));
      result = await hooks.call(controller, 'parse', targetUrl, {
        'input': utf8.decode(response.bodyBytes),
      });
    } else {
      await hooks.call(controller, 'prepare', currentUrl);
      await waitForParserState(
        () async => await hooks.call(controller, 'ready', currentUrl) == true,
      );
      result = await hooks.call(controller, 'parsePage', currentUrl);
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
    return validateParserResult(result, hooks.site);
  } finally {
    await view?.dispose();
  }
}
