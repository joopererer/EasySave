import 'dart:convert';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'site_registry.dart';

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
      throw const FormatException('Invalid parser hook result');
    }
    return decoded['value'];
  }
}
