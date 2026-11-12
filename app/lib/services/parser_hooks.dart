import 'dart:convert';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../core/dev_log.dart';
import 'site_registry.dart';

/// A parse holds one verified script and matching site definition throughout.
class ParserHooks {
  ParserHooks(this.script, this.site);
  final String script;
  final SiteDefinition site;

  /// Error codes this App renders with their own copy and action.
  ///
  /// The parser bundle is hot-updated, so it must not assume the App knows a
  /// code it introduced after this build: without `media_unavailable` the
  /// parser answers LOGIN_REQUIRED for the same failure, and this App's login
  /// button still gets the user to the Instagram login page.
  static const List<String> capabilities = ['media_unavailable'];

  String expression(
    String hook,
    String url, [
    Map<String, dynamic> extra = const {},
  ]) =>
      'EasySaveParser.moduleCall(${jsonEncode(site.parserModule)},${jsonEncode(hook)},${jsonEncode({'url': url, 'site': site.data, 'caps': capabilities, ...extra})})';

  /// Run one hook and unwrap `{value: ...}`.
  ///
  /// An empty answer is tolerated where it is meaningful (see [_emptyAnswer]):
  /// a page that already is the canonical one makes `navigate` return nothing
  /// at all. Anything else that does not look like `{value: ...}` is a real
  /// mismatch and is logged with `[ParseMismatch] check=HOOK_RESULT` before
  /// failing, so a device log names the hook instead of hiding a bare
  /// FormatException.
  Future<dynamic> call(
    InAppWebViewController controller,
    String hook,
    String url, [
    Map<String, dynamic> extra = const {},
  ]) async {
    final raw = await controller.evaluateJavascript(
      source: expression(hook, url, extra),
    );
    return unwrapHookResult(raw, hook: hook, site: site);
  }
}

/// Unwrap one `EasySaveParser.moduleCall` answer.
///
/// Split out of [ParserHooks.call] so the accepted and rejected shapes are
/// unit-testable without a live WebView.
dynamic unwrapHookResult(
  dynamic raw, {
  required String hook,
  required SiteDefinition site,
}) {
  if (raw == null || (raw is String && raw.trim().isEmpty)) {
    final allowed = _emptyAnswer(hook);
    if (allowed.ok) {
      return allowed.value;
    }
  }
  dynamic decoded;
  var parseFailed = false;
  if (raw is String) {
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      parseFailed = true;
    }
  } else {
    decoded = raw;
  }
  if (!parseFailed && decoded is Map && decoded.containsKey('value')) {
    return decoded['value'];
  }
  _logHookResult(
    hook,
    site: site,
    actual: parseFailed ? 'type=string_not_json' : 'type=${decoded.runtimeType}',
    fields: decoded is Map
        ? decoded.keys.map((key) => '$key').take(8).join(',')
        : null,
  );
  throw FormatException('Invalid parser hook result');
}

/// What an empty answer means for [hook]; `ok: false` means empty itself is
/// the mismatch.
({bool ok, dynamic value}) _emptyAnswer(String hook) => switch (hook) {
  'install' || 'navigate' || 'account' => (ok: true, value: null),
  'ready' || 'prepare' => (ok: true, value: false),
  _ => (ok: false, value: null),
};

void _logHookResult(
  String hook, {
  required SiteDefinition site,
  required String actual,
  String? fields,
}) {
  // Only the hook name, the value type and its field names are logged; the
  // page address (and any query parameter it carries) never is.
  DevLog.write(
    'ParseMismatch', // i18n:ignore 日志
    'check=HOOK_RESULT site=${site.id} post=- hook=$hook '
    'expected={value:<json>} actual=$actual'
    '${fields == null ? '' : ' fields=$fields'}',
  );
}

/// Fixed vocabulary of the parser's `[IgParse]` diagnostic.
///
/// The parser may say where Instagram data came from and how much of it it
/// got; nothing else is accepted. A page address, query, cookie or account
/// value can never reach the log, because the whole line must match.
final RegExp _igParseLinePattern = RegExp(
  r'^source=(?:api|graphql|embedded_json|og_meta) '
  r'mediaType=(?:image|video|carousel) '
  r'items=\d{1,4} loginWall=[01]$',
);

/// Record one `[IgParse] source=... mediaType=... items=N loginWall=0|1` line.
void logIgParseDiagnostic(String message) {
  const prefix = '[IgParse] ';
  if (!message.startsWith(prefix)) return;
  final body = message.substring(prefix.length);
  if (!_igParseLinePattern.hasMatch(body)) return;
  DevLog.write('IgParse', body); // i18n:ignore 日志
}
