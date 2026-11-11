// Copyright 2026 EasySave. All rights reserved.
//
// Two TikTok regressions from build 12:
//
// 1. the first attempt died with "FormatException: Invalid parser hook result"
//    and every retry then showed INVALID_PAGE without a single
//    [ParseMismatch] line;
// 2. after landing on the canonical page, `navigate` legitimately answers
//    "nothing to do" — that empty answer must not be a format error.
//
// The checks below drive the same decision the WebView callback runs
// (navigateStep) plus the hook-result validation, so a short-link landing page
// -> canonical page -> parse sequence is covered end to end without a device.

import 'dart:convert';

import 'package:easysave/core/dev_log.dart';
import 'package:easysave/services/parse_service.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

const _shortLink = 'https://vm.tiktok.com/ZN8UgXBcu/';
const _canonical =
    'https://www.tiktok.com/@xo901970f6s/video/7688352288666045718';
const _id = '7688352288666045718';

void main() {
  tearDown(SiteRegistry.useBuiltin);

  final site = SiteRegistry.current.byId('tiktok')!;

  Future<NavigateStep> step(
    String currentUrl, {
    required dynamic answer,
    bool alreadyNavigated = false,
  }) => navigateStep(
    site: site,
    currentUrl: currentUrl,
    alreadyNavigated: alreadyNavigated,
    navigate: () async => answer,
  );

  group('TikTok navigation matches v1.9.0 onLoadStop', () {
    test('a short-link landing page waits for the redirect', () async {
      final result = await step(
        _shortLink,
        answer: {'wait': true},
      );
      expect(result.kind, NavigateKind.wait);
    });

    test('the landing page is left alone when the hook says nothing', () async {
      final result = await step(_shortLink, answer: null);
      expect(result.kind, NavigateKind.wait);
    });

    test('the canonical page is loaded once from a post-id-only URL', () async {
      final result = await step(
        'https://www.tiktok.com/@user/video/$_id?_r=1&_t=abc',
        answer: {'url': _canonical},
      );
      expect(result.kind, NavigateKind.load);
      expect(result.url, _canonical);
      expect(result.url, isNot(contains('?')));
    });

    test('already navigated: a second target is ignored and parsing starts',
        () async {
      final result = await step(
        'https://www.tiktok.com/@user/video/$_id',
        answer: {'url': _canonical},
        alreadyNavigated: true,
      );
      expect(result.kind, NavigateKind.parse);
    });

    test('already on the canonical page with an empty answer parses', () async {
      final result = await step(_canonical, answer: null);
      expect(result.kind, NavigateKind.parse);
    });

    test('an empty answer no longer aborts with a format error', () async {
      for (final answer in <dynamic>[null, '', '   ']) {
        final result = await step(_canonical, answer: answer);
        expect(result.kind, NavigateKind.parse, reason: 'answer=$answer');
      }
    });

    test('a target outside the site is reported, not loaded', () async {
      final result = await step(
        _canonical,
        answer: {'url': 'https://evil.example.test/video/$_id'},
      );
      expect(result.kind, NavigateKind.invalid);
    });
  });

  group('hook result validation', () {
    late List<String> logged;

    setUp(() {
      logged = [];
      final original = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) logged.add(message);
      };
      addTearDown(() => debugPrint = original);
    });

    test('a well formed answer is unwrapped', () {
      expect(
        unwrapHookResult(
          jsonEncode({'value': {'url': _canonical}}),
          hook: 'navigate',
          site: site,
        ),
        {'url': _canonical},
      );
      expect(
        unwrapHookResult(jsonEncode({'value': true}), hook: 'ready', site: site),
        isTrue,
      );
    });

    test('an empty navigate answer is null and is silent', () {
      expect(unwrapHookResult(null, hook: 'navigate', site: site), isNull);
      expect(unwrapHookResult('', hook: 'navigate', site: site), isNull);
      expect(logged, isEmpty);
    });

    test('a broken hook answer logs HOOK_RESULT and still fails', () {
      expect(
        () => unwrapHookResult(
          '<html>not json</html>',
          hook: 'parsePage',
          site: site,
        ),
        throwsA(isA<FormatException>()),
      );
      final line = logged.firstWhere((l) => l.contains('check=HOOK_RESULT'));
      expect(line, contains('check=HOOK_RESULT'));
      expect(line, contains('site=tiktok'));
      expect(line, contains('hook=parsePage'));
      expect(line, contains('actual=type=string_not_json'));
      // Never the page address, so no query parameter can leak.
      expect(line.contains('http'), isFalse);
      expect(line.contains('?'), isFalse);
    });

    test('an unexpected object logs its field names only', () {
      expect(
        () => unwrapHookResult(
          jsonEncode({'status': 'ok', 'data': {'secret': 'x'}}),
          hook: 'parse',
          site: site,
        ),
        throwsA(isA<FormatException>()),
      );
      final line = logged.firstWhere((l) => l.contains('check=HOOK_RESULT'));
      expect(line, contains('fields=status,data'));
      expect(line.contains('secret'), isFalse);
    });

    test('the [ParseMismatch] line survives DevLog redaction', () {
      const message =
          'check=HOOK_RESULT site=tiktok post=- expected={value:<json>} '
          'actual=type=null tolerated=1';
      expect(DevLog.scrub(message), message);
    });
  });
}
