import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:easysave/services/links.dart';

void main() {
  final cases =
      jsonDecode(
            File('../spec/test-vectors/site-links.json').readAsStringSync(),
          )
          as List;
  for (final row in cases.cast<Map>()) {
    test('shared Kotlin/Dart recognition: ${row['text']}', () {
      SiteRegistry.useBuiltin();
      final link = extractLink(row['text'] as String);
      expect(
        link == null ? null : SiteRegistry.current.match(link)?.id,
        row['siteId'],
      );
    });
  }
  test('unknown platform falls back to no site; no small-red-book default', () {
    expect(SiteRegistry.current.match('https://unknown.example/post'), isNull);
    expect(SiteRegistry.current.byId('unknown'), isNull);
  });
}
