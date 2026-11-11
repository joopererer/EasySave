import 'dart:convert';
import 'dart:io';
import 'package:easysave/services/parser_config_contract.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map payload() =>
      jsonDecode(File('assets/parser/builtin-manifest.json').readAsStringSync())
          as Map;
  test('current builtin meets App contract', () {
    expect(() => validateAppParserConfig(payload()), returnsNormally);
  });
  for (final field in ['openDomains', 'probeUrls', 'sessionCookieNames']) {
    test('missing $field rejects bundle with named field', () {
      final p = payload();
      final xhs = (p['sites'] as List).cast<Map>().firstWhere(
        (s) => s['id'] == 'xhs',
      );
      (xhs['auth'] as Map).remove(field);
      expect(
        () => validateAppParserConfig(p),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'field',
            'sites.xhs.auth.$field',
          ),
        ),
      );
    });
  }
  test('old short link configuration is rejected', () {
    final p = payload();
    final xhs = (p['sites'] as List).cast<Map>().firstWhere(
      (s) => s['id'] == 'xhs',
    );
    (xhs['shortLinks'] as List).cast<Map>().first.remove('stopAtPost');
    expect(
      () => validateAppParserConfig(p),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'field',
          'sites.xhs.shortLinks.stopAtPost',
        ),
      ),
    );
  });
}
