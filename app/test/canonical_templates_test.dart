import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:provenance_dart/provenance_dart.dart' show normalizeUrl;

void main() {
  final sites =
      jsonDecode(File('../config/sites.json').readAsStringSync()) as List;
  for (final site in sites.cast<Map>()) {
    test('canonicalTemplate remains stable for ${site['id']}', () {
      final rule = site['normalize'] as Map;
      final url = (rule['canonicalTemplate'] as String).replaceAll(
        '{id}',
        Uri.encodeComponent(rule['exampleId'] as String),
      );
      expect(normalizeUrl(url), url);
    });
  }
  test(
    'unknown-domain tracking and fragment cleanup is accepted; repeated queries are a known package defect',
    () {
      expect(
        normalizeUrl('https://unknown.example/post?id=42&utm_source=a#part'),
        'https://unknown.example/post?id=42',
      );
      final result = Uri.parse(
        normalizeUrl('https://unknown.example/post?id=1&id=2'),
      );
      expect(result.queryParametersAll['id'], hasLength(1));
    },
  );
}
