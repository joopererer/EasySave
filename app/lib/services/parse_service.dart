// Headless parsing: load a post URL (short links follow redirects
// automatically), inject parser.js and execute EasySaveParser.parsePage().
// Throws [ParseFailure] so callers can distinguish login walls.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../core/models.dart';
import '../core/parse.dart';
import 'links.dart';
import 'update_service.dart';

class ParseFailure implements Exception {
  ParseFailure(this.code, this.message);
  final String code;
  final String message;
}

Future<T> _withTimeout<T>(Future<T> Function() run, String what) {
  return run().timeout(
    const Duration(seconds: 20),
    onTimeout: () =>
        throw ParseFailure(ParseErrorCode.timeout, '$what超时（20秒），请重试'),
  );
}

/// Load [url] headlessly and parse the post it resolves to.
Future<ParsedPost> parsePostUrl(String url) {
  return _withTimeout(() async {
    final resolved = await resolveShortLink(
      url,
    ).timeout(const Duration(seconds: 10), onTimeout: () => url);
    return (await _parseInner(resolved)).data;
  }, '加载页面');
}

/// Same as [parsePostUrl] but keeps the raw image entries for diagnostics.
Future<ParseOutcome> parsePostOutcome(String url) {
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

Future<ParseOutcome> _parseInner(String url) async {
  // Remote platform switch check: do not start WebView or make requests if disabled
  final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
  String platform = '';
  if (isXhsHost(host)) {
    platform = 'xhs';
  } else if (isInstagramHost(host)) {
    platform = 'instagram';
  }

  if (platform.isNotEmpty && !ParserManager.instance.isPlatformEnabled(platform)) {
    final notice = ParserManager.instance.getMaintenanceNotice(platform) ??
        '该平台解析服务维护中，请稍后再试';
    throw ParseFailure(ParseErrorCode.blocked, notice);
  }

  final loaded = Completer<void>();
  InAppWebViewController? readyController;
  HeadlessInAppWebView? headless;
  try {
    headless = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: WebUri.uri(Uri.parse(url))),
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
