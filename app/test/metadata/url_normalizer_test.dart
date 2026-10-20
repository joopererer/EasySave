// Copyright 2026 EasySave. All rights reserved.
// Tests for URL normalization against test-vectors/urls.json

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:easysave/metadata/url_normalizer.dart';

void main() {
  group('URL Normalizer', () {
    late List<dynamic> testCases;

    setUpAll(() {
      // Read test vectors from provenance-spec submodule
      final projectRoot = Directory.current.path.endsWith('app')
          ? Directory.current.parent.path
          : Directory.current.path;
      final vectorPath = '$projectRoot/docs/provenance-spec/test-vectors/urls.json';
      final file = File(vectorPath);
      
      if (!file.existsSync()) {
        throw Exception('Test vector not found: $vectorPath');
      }
      
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      testCases = json['cases'] as List<dynamic>;
    });

    test('passes all test-vectors/urls.json cases', () {
      for (final testCase in testCases) {
        final input = testCase['in'] as String;
        final expected = testCase['out'] as String;
        final platform = testCase['platform'] as String;
        
        final actual = normalizeUrl(input);
        
        expect(
          actual,
          expected,
          reason: 'Platform: $platform\nInput: $input',
        );
      }
    });
    
    test('idempotence: normalizing twice yields same result', () {
      for (final testCase in testCases) {
        final input = testCase['in'] as String;
        final first = normalizeUrl(input);
        final second = normalizeUrl(first);
        
        expect(second, first, reason: 'Input: $input');
      }
    });
  });
}
