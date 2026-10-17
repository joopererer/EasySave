// Headless parsing: load a post URL (short links follow redirects
// automatically), inject parser.js and execute EasySaveParser.
// Throws [ParseFailure] so callers can distinguish login walls.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;

import '../core/models.dart';
import '../core/parse.dart';
import 'auth.dart';
import 'links.dart';
import 'update_service.dart';

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
  _checkPlatform(url);
  return _withTimeout(() async {
    final resolved = await resolveShortLink(
      url,
    ).timeout(const Duration(seconds: 10), onTimeout: () => url);
    return (await _parseInner(resolved)).data;
  }, '加载页面');
}

/// Same as [parsePostUrl] but keeps the raw image entries for diagnostics.
Future<ParseOutcome> parsePostOutcome(String url) {
  _checkPlatform(url);
  return _withTimeout(() async {
    final resolved = await resolveShortLink(
      url,
    ).timeout(const Duration(seconds: 10), onTimeout: () => url);
    return _parseInner(resolved);
  }, '加载页面');
}

class ParseOutcome {
  ParseOutcome({required this.data, required this.rawImages});

  final ParsedPost data;
  final List<RawImageEntry> rawImages;
}

Future<ParseOutcome> _runParserJs(String input, String pageUrl) async {
  final loaded = Completer<void>();
  InAppWebViewController? readyController;
  HeadlessInAppWebView? headless;
  try {
    headless = HeadlessInAppWebView(
      initialData: InAppWebViewInitialData(data: '<html><body></body></html>'),
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
    final match = RegExp(
      r'/(?:explore|discovery/item)/([a-f0-9]{24})',
      caseSensitive: false,
    ).firstMatch(url);
    if (match != null) {
      final noteId = match.group(1);
      targetUrl = 'https://www.xiaohongshu.com/explore/$noteId';
    }
  }

  final loaded = Completer<void>();
  InAppWebViewController? readyController;
  HeadlessInAppWebView? headless;
  try {
    headless = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: WebUri.uri(Uri.parse(targetUrl))),
      initialSettings: InAppWebViewSettings(
        userAgent: isXhs ? loginUserAgent(PlatformKind.xhs) : null,
      ),
      // XHS pages auto-navigate to xhsdiscover:// (app-open scheme) after
      // load. Cancel every non-http(s) navigation so the WebView stays on
      // the note page, whose DOM/state holds the data we parse.
      shouldOverrideUrlLoading: (controller, navigationAction) async {
        final scheme = navigationAction.request.url?.scheme.toLowerCase() ?? '';
        if (scheme == 'http' || scheme == 'https') {
          return NavigationActionPolicy.ALLOW;
        }
        return NavigationActionPolicy.CANCEL;
      },
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
    await loaded.future.timeout(const Duration(seconds: 18));
    // Let SPA frameworks settle after the load event.
    await Future<void>.delayed(const Duration(seconds: 2));
    final controller = readyController ?? headless.webViewController;
    if (controller == null) {
      throw ParseFailure('INVALID_PAGE', '页面未能加载');
    }

    final parserJs = await ParserManager.instance.getActiveScript();
    dynamic jsResult;
    try {
      await controller.evaluateJavascript(source: parserJs);
      jsResult = await controller.evaluateJavascript(
        source: 'EasySaveParser.parsePage()',
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
