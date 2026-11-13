// Compatibility proof for the parser 1.4.16 push to an installed v1.10.2 App.
//
// This file was written against the v1.10.2 worktree (see git worktree history
// for the v1.10.2 checkout). It runs the real 1.4.16 bundles through
// EasySaveParser.moduleCall exactly as the App does (node harness, page DOM
// stubbed) and then feeds the answer through the *installed App's* own error
// copy, result validation and error card. On master (v1.10.3) the App maps
// MEDIA_UNAVAILABLE to re-login guidance rather than a plain retry, so the
// copy/card assertions below target v1.10.3's error_copy.dart; every
// parser-side fact (MEDIA_UNAVAILABLE answer, no data/cover, console
// vocabulary, gated LOGIN_REQUIRED) remains pinned to the 1.4.16 bundles.
//
// Run: flutter test test/v1102_ig_media_unavailable_compat_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:easysave/core/error_copy.dart';
import 'package:easysave/services/ai_label_log.dart';
import 'package:easysave/services/parse_service.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:easysave/widgets/shared.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 1.4.16 exactly as it was built in commit 72aad7f (no App capability gate).
const _asCommitted =
    'test/v1102_ig_compat/parser_1416_as_committed.js';

/// 1.4.16 with the App capability gate added on fix/parser-ig-og-fallback.
const _gated = 'test/v1102_ig_compat/parser_1416_gated.js';

const _reelHtml = 'test/v1102_ig_compat/ig_og_only_reel.html';
const _postHtml = 'test/v1102_ig_compat/ig_og_only_post.html';
const _reelUrl = 'https://www.instagram.com/reel/DflxolxpdHT/';
const _postUrl = 'https://www.instagram.com/p/ig_og_only_post/';

class HookRun {
  HookRun(this.result, this.console);

  final Map<String, dynamic> result;
  final List<String> console;

  String get code => (result['error'] as Map)['code'] as String;
  String get message => (result['error'] as Map)['message'] as String;
}

Future<HookRun> runHook(
  String bundle,
  String html,
  String url, {
  bool caps = false,
}) async {
  final node = await Process.run(
    'node',
    [
      'test/v1102_ig_compat/harness.mjs',
      bundle,
      html,
      url,
      'parsePage',
      caps ? 'caps' : 'nocaps',
    ],
    // node always writes UTF-8; the Windows default code page would mangle it.
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (node.exitCode != 0) {
    fail('node harness exited ${node.exitCode}: ${node.stderr}');
  }
  final decoded = jsonDecode(node.stdout as String) as Map<String, dynamic>;
  return HookRun(
    (decoded['value'] as Map).cast<String, dynamic>(),
    (decoded['console'] as List).cast<String>(),
  );
}

void main() {
  final instagram = SiteRegistry.current.byId('instagram')!;

  group('v1.10.2 with parser 1.4.16 as merged (72aad7f)', () {
    late HookRun reel;

    setUpAll(() async {
      reel = await runHook(_asCommitted, _reelHtml, _reelUrl);
    });

    test('the parser answers MEDIA_UNAVAILABLE to an App without the gate', () {
      expect(reel.result['ok'], isFalse);
      expect(reel.code, 'MEDIA_UNAVAILABLE');
      expect(reel.message, '未能获取视频，请检查 Instagram 登录后重试。');
    });

    test('the installed App maps MEDIA_UNAVAILABLE to re-login guidance', () {
      final copy = errorCopyFor(reel.code);
      expect(copy.action, ErrorAction.goLogin);
      expect(copy.message,
          '未能获取该 Instagram 媒体，请在“我的”页检查 Instagram 登录后重试');
      expect(displayErrorMessage(reel.code, reel.message), reel.message);
    });

    test('re-login guidance is the only action the card offers', () async {
      final copy = errorCopyFor(reel.code);
      expect(copy.action, ErrorAction.goLogin);
    });

    testWidgets('the error card renders without crashing and only offers 去登录', (
      tester,
    ) async {
      final actions = <ErrorAction>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ErrorCard(
              code: reel.code,
              message: reel.message,
              onAction: (action) async => actions.add(action),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text(reel.message), findsOneWidget);
      expect(find.text('去登录'), findsOneWidget);
      expect(find.text('重试'), findsNothing);
      await tester.tap(find.text('去登录'));
      await tester.pump();
      expect(actions, [ErrorAction.goLogin]);
    });

    test('no record can be created: validation throws before ParseOutcome', () {
      // Saving and history rows require ParseOutcome.data, which only exists
      // for a successful result — this failure never produces one.
      expect(
        () => validateParserResult(reel.result, instagram),
        throwsA(
          isA<ParseFailure>()
              .having((e) => e.code, 'code', 'MEDIA_UNAVAILABLE')
              .having((e) => e.message, 'message', reel.message),
        ),
      );
    });
  });

  group('v1.10.2 with the gated parser 1.4.16', () {
    late HookRun reel;
    late HookRun seated;

    setUpAll(() async {
      reel = await runHook(_gated, _reelHtml, _reelUrl);
      seated = await runHook(_gated, _reelHtml, _reelUrl, caps: true);
    });

    test('an App that declares nothing gets LOGIN_REQUIRED', () {
      expect(reel.result['ok'], isFalse);
      expect(reel.code, 'LOGIN_REQUIRED');
      expect(reel.message, contains('登录 Instagram'));
    });

    test('v1.10.2 maps it to its own login copy and a 去登录 button', () {
      expect(errorCopyFor(reel.code).action, ErrorAction.goLogin);
      expect(errorCopyFor(reel.code).message, contains('需要先登录'));
      expect(displayErrorMessage(reel.code, reel.message), reel.message);
    });

    testWidgets('the error card offers 去登录 and calls goLogin', (tester) async {
      final actions = <ErrorAction>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ErrorCard(
              code: reel.code,
              message: reel.message,
              onAction: (action) async => actions.add(action),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text(reel.message), findsOneWidget);
      expect(find.text('去登录'), findsOneWidget);
      expect(find.text('重试'), findsNothing);
      await tester.tap(find.text('去登录'));
      await tester.pump();
      expect(actions, [ErrorAction.goLogin]);
    });

    test('the capability keeps MEDIA_UNAVAILABLE for a capable App', () {
      expect(seated.code, 'MEDIA_UNAVAILABLE');
    });

    test('still no record: validation throws for the downgraded failure too', () {
      expect(
        () => validateParserResult(reel.result, instagram),
        throwsA(
          isA<ParseFailure>().having((e) => e.code, 'code', 'LOGIN_REQUIRED'),
        ),
      );
    });
  });

  group('public single-image post that only exposes og:image still fails', () {
    test('as merged: MEDIA_UNAVAILABLE, no item, no cover URL', () async {
      final run = await runHook(_asCommitted, _postHtml, _postUrl);
      expect(run.result['ok'], isFalse);
      expect(run.code, 'MEDIA_UNAVAILABLE');
      expect(run.result.containsKey('data'), isFalse);
      expect(jsonEncode(run.result), isNot(contains('single-post-cover')));
    });

    test('gated without capability: LOGIN_REQUIRED, no item, no cover URL', () async {
      final run = await runHook(_gated, _postHtml, _postUrl);
      expect(run.result['ok'], isFalse);
      expect(run.code, 'LOGIN_REQUIRED');
      expect(jsonEncode(run.result), isNot(contains('single-post-cover')));
    });
  });

  group('[IgParse] console output on v1.10.2', () {
    test('the parser emits only the fixed vocabulary, never a page address', () async {
      final run = await runHook(_asCommitted, _reelHtml, _reelUrl);
      expect(run.console, isNotEmpty);
      for (final line in run.console) {
        expect(
          RegExp(
            r'^\[IgParse\] source=(?:api|graphql|embedded_json|og_meta) '
            r'mediaType=(?:image|video|carousel) items=\d{1,4} loginWall=[01]$',
          ).hasMatch(line),
          isTrue,
          reason: line,
        );
        expect(line, isNot(contains('http')));
        expect(line, isNot(contains('instagram.com')));
        expect(line, isNot(contains('DflxolxpdHT')));
      }
    });

    test('v1.10.2 writes nothing: logUnknownAiLabel drops the line', () {
      final written = <String>[];
      final previous = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) written.add(message);
      };
      addTearDown(() => debugPrint = previous);

      for (final line in [
        '[IgParse] source=og_meta mediaType=video items=0 loginWall=0',
        '[IgParse] source=api mediaType=carousel items=16 loginWall=0',
        '[IgParse] source=og_meta mediaType=image items=0 loginWall=1 '
            'https://www.instagram.com/p/PRIVATE/?igsh=PRIVATE',
      ]) {
        logUnknownAiLabel(line);
      }
      expect(written, isEmpty);
    });
  });
}
