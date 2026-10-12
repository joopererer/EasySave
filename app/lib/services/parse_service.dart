// Headless parsing: load a post URL (short links follow redirects
// automatically), then hand page data to the pure core parsers.
// Throws [ParseFailure] so callers can distinguish login walls.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../core/instagram.dart';
import '../core/models.dart';
import '../core/xhs.dart';

class ParseFailure implements Exception {
  ParseFailure(this.code, this.message);
  final String code;
  final String message;
}

Future<T> _withTimeout<T>(Future<T> Function() run, String what) {
  return run().timeout(
    const Duration(seconds: 20),
    onTimeout: () => throw ParseFailure('TIMEOUT', '$what超时（20秒），请重试'),
  );
}

/// Load [url] headlessly and parse the post it resolves to.
Future<ParsedPost> parsePostUrl(String url) {
  return _withTimeout(() => _parseInner(url), '加载页面');
}

Future<ParsedPost> _parseInner(String url) async {
  final loaded = Completer<void>();
  InAppWebViewController? readyController;
  HeadlessInAppWebView? headless;
  try {
    headless = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: WebUri.uri(Uri.parse(url))),
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
    final finalUrl = (await controller.getUrl())?.toString() ?? url;
    final host = Uri.tryParse(finalUrl)?.host.toLowerCase() ?? '';
    final isXhs = host == 'xiaohongshu.com' ||
        host.endsWith('.xiaohongshu.com') ||
        host == 'xhslink.com' ||
        host.endsWith('.xhslink.com') ||
        host == 'xhslink.cn' ||
        host.endsWith('.xhslink.cn');

    ParseResult result;
    if (isXhs) {
      result = await _parseXhsPage(controller, finalUrl);
    } else {
      result = await _parseInstagramPage(controller, finalUrl);
    }
    if (!result.ok || result.data == null) {
      throw ParseFailure(
        result.error?.code ?? 'INVALID_PAGE',
        result.error?.message ?? '解析失败',
      );
    }
    return result.data!;
  } finally {
    await headless?.dispose();
  }
}

Future<ParseResult> _parseXhsPage(
  InAppWebViewController controller,
  String finalUrl,
) async {
  // Preferred: structured state straight from the page context.
  try {
    final raw = await controller.evaluateJavascript(
      source: 'JSON.stringify(window.__INITIAL_STATE__)',
    );
    if (raw is String && raw.isNotEmpty && raw != 'null') {
      final decoded = jsonDecode(raw);
      final via = parseXhsState(decoded, finalUrl);
      if (via.ok) return via;
    }
  } catch (_) {
    // Fall through to full-HTML parsing.
  }
  final html = await _outerHtml(controller);
  if (html == null) {
    return ParseResult.err(ParseError(
      code: ParseErrorCode.loginRequired,
      message: '无法读取页面内容',
    ));
  }
  return parseXhs(html, finalUrl);
}

Future<ParseResult> _parseInstagramPage(
  InAppWebViewController controller,
  String finalUrl,
) async {
  final html = await _outerHtml(controller);
  if (html == null) {
    return ParseResult.err(ParseError(
      code: ParseErrorCode.loginRequired,
      message: '无法读取页面内容',
    ));
  }
  return parseInstagram(html, finalUrl);
}

Future<String?> _outerHtml(InAppWebViewController controller) async {
  try {
    final raw = await controller.evaluateJavascript(
      source: 'document.documentElement.outerHTML',
    );
    if (raw is String && raw.isNotEmpty) return raw;
  } catch (_) {
    // Fall through to the data-sjs fallback below.
  }
  // Safety net for very large documents: only the scripts the parser reads.
  try {
    final parts = await controller.evaluateJavascript(source: '''
(() => {
  const out = [];
  document.querySelectorAll('script[data-sjs]').forEach((s) => {
    if (s.textContent) out.push('<script data-sjs>' + s.textContent + '</scr' + 'ipt>');
  });
  return out.join('\\n');
})()
''');
    if (parts is String && parts.isNotEmpty) return parts;
  } catch (_) {
    // Ignore; caller reports the failure.
  }
  return null;
}
