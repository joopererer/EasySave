// Fixture-driven parity tests: every *.html under spec/fixtures is parsed
// and deep-compared with its sibling *.expected.json. Adding a fixture
// needs no test-code changes.
import 'dart:convert';
import 'dart:io';

import 'package:easysave/core/instagram.dart';
import 'package:easysave/core/xhs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final root = Directory('../spec/fixtures');
  for (final platformDir in ['xhs', 'instagram']) {
    final dir = Directory('${root.path}/$platformDir');
    final cases =
        dir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.html'))
            .map((f) => f.uri.pathSegments.last.replaceAll('.html', ''))
            .where(
              (name) => File('${dir.path}/$name.expected.json').existsSync(),
            )
            .toList()
          ..sort();
    group('$platformDir fixtures', () {
      if (cases.isEmpty) {
        test('has fixtures to test', () => expect(cases, isNotEmpty));
      }
      for (final name in cases) {
        test('$name.html matches $name.expected.json', () {
          final html = File('${dir.path}/$name.html').readAsStringSync();
          final expected = jsonDecode(
            File('${dir.path}/$name.expected.json').readAsStringSync(),
          );
          final id = expected is Map && expected['id'] is String
              ? expected['id'] as String
              : name;
          final result = platformDir == 'xhs'
              ? parseXhs(html, 'https://www.xiaohongshu.com/explore/$id')
              : parseInstagram(html, 'https://www.instagram.com/p/$id/');

          if (expected is Map && expected.containsKey('error')) {
            expect(result.ok, isFalse);
            final err = (expected['error'] as Map)['code'];
            expect(result.error?.code, equals(err));
          } else {
            expect(result.ok, isTrue);
            expect(result.data?.toJson(), equals(expected));
          }
        });
      }
    });
  }
}
