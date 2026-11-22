// Compatibility proof for the parser 1.4.17 push.
//
// The parser bundle is hot-updated, so the same bundle runs inside Apps that
// were built before it. This file runs the real bundle through
// EasySaveParser.moduleCall exactly as the App does (node harness, page DOM
// stubbed) and then feeds the answer through the *installed App's* own error
// copy, result validation, error card and download planning.
//
// It is written against the APIs the v1.10.2, v1.10.3 and v1.11.0 App builds
// all have (`errorCopyFor`, `displayErrorMessage`, `ErrorCard`,
// `validateParserResult`, `MediaItem.fromJson`, `planFiles`, `MediaRequestPolicy.resourcesFor`),
// so the very same file runs unchanged in the v1.10.2 / v1.10.3 / v1.11.0
// worktrees. A copy of the 1.4.17 bundle placed at
// `test/parser_1417_compat/parser_1.4.17.js` wins over the App's own asset, which
// is how the older worktrees are pointed at this release.
//
// Run: flutter test test/parser_1417_compat_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:easysave/core/error_copy.dart';
import 'package:easysave/core/models.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/media_request_policy.dart';
import 'package:easysave/services/parse_service.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:easysave/widgets/shared.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _harnessPath = 'test/parser_1417_compat/harness.mjs';

/// The 1.4.17 bundle under test: the worktree copy when present, otherwise the
/// bundle this build ships.
String get _bundle => File('test/parser_1417_compat/parser_1.4.17.js').existsSync()
    ? 'test/parser_1417_compat/parser_1.4.17.js'
    : 'assets/parser/parser.js';

const _xhsUrl = 'https://www.xiaohongshu.com/explore/6aca089a000000000a01efb4';
/// Where Xiaohongshu sends a note request it will not serve (`/explore`, no id).
const _xhsLandingUrl = 'https://www.xiaohongshu.com/explore';
const _xhsLiveUrl = 'https://www.xiaohongshu.com/explore/6a342fd20000000021017867';
const _igUrl = 'https://www.instagram.com/p/ig_session_expired/';
const _igDeletedUrl = 'https://www.instagram.com/p/ig_post_deleted/';

class HookRun {
  HookRun(this.value);

  final Map<String, dynamic> value;

  /// The error a failure carries. `classify` answers the error object itself
  /// (the App puts it back as `{ok: false, error: <this>}`, exactly as
  /// parse_service.dart does), while a parse answer nests it under `error`.
  Map<String, dynamic> get error =>
      (value['error'] as Map?)?.cast<String, dynamic>() ?? value;

  String get code => error['code'] as String;
  String get message => error['message'] as String;

  /// The failing result the App validates.
  Map<String, dynamic> get asResult => {'ok': false, 'error': error};
  Map<String, dynamic> get data => (value['data'] as Map).cast<String, dynamic>();
  List<Map<String, dynamic>> get items =>
      (data['items'] as List).cast<Map<String, dynamic>>();
}

Future<HookRun> runHook(
  String platform,
  String fixture,
  String url,
  String hook, {
  bool? loggedIn,
  String? errorCode,
  String? errorMessage,
  String doc = 'page',
}) async {
  // Every assertion below is written against 1.4.17's own answers, so a stale
  // bundle (an older asset in a worktree, say) fails on the first expectation.
  final node = await Process.run('node', [
    _harnessPath,
    _bundle,
    platform,
    '../spec/fixtures/$fixture',
    url,
    hook,
    loggedIn == null ? '-' : (loggedIn ? '1' : '0'),
    errorCode ?? '-',
    errorMessage ?? '-',
    doc,
  ], stdoutEncoding: utf8, stderrEncoding: utf8);
  if (node.exitCode != 0) {
    fail('node harness exited ${node.exitCode}: ${node.stderr}');
  }
  final decoded = jsonDecode(node.stdout as String) as Map<String, dynamic>;
  if (!decoded.containsKey('value')) {
    fail('harness answered without {value}: ${node.stdout}');
  }
  return HookRun((decoded['value'] as Map).cast<String, dynamic>());
}

/// Feeds one failure through the installed App's error card and returns the
/// actions it offered.
Future<List<ErrorAction>> pumpErrorCard(WidgetTester tester, HookRun run) async {
  final actions = <ErrorAction>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ErrorCard(
          code: run.code,
          message: run.message,
          onAction: (action) async => actions.add(action),
        ),
      ),
    ),
  );
  expect(tester.takeException(), isNull);
  expect(find.text(run.message), findsOneWidget);
  final copy = errorCopyFor(run.code);
  final button = switch (copy.action) {
    ErrorAction.goLogin => '去登录',
    ErrorAction.backHome => '返回首页',
    ErrorAction.retry => '重试',
    ErrorAction.repaste => '重新粘贴',
    ErrorAction.openUrl => '打开原链接',
  };
  expect(find.text(button), findsOneWidget);
  await tester.tap(find.text(button));
  await tester.pump();
  return actions;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(SiteRegistry.useBuiltin);
  tearDown(SiteRegistry.useBuiltin);

  group('an App that believes it is signed in meets an expired session', () {
    const parserMessage = 'Xiaohongshu returned an authenticated-only shell without note data.';
    late HookRun xhs;
    late HookRun ig;

    setUpAll(() async {
      xhs = await runHook('xhs', 'xhs/xhs_session_expired.html', _xhsUrl, 'classify',
          loggedIn: true, errorCode: 'LOGIN_REQUIRED', errorMessage: parserMessage);
      ig = await runHook('instagram', 'instagram/ig_session_expired.html', _igUrl, 'classify',
          loggedIn: true,
          errorCode: 'LOGIN_REQUIRED',
          errorMessage: '该帖子需要登录 Instagram 后才能查看。');
    });

    test('the parser answers LOGIN_REQUIRED with the re-login prompt, not "gone"', () {
      expect(xhs.code, 'LOGIN_REQUIRED');
      expect(xhs.message, '登录可能已失效，请重新登录');
      expect(ig.code, 'LOGIN_REQUIRED');
      expect(ig.message, '登录可能已失效，请重新登录');
    });

    test('the App keeps its own login action even though the engine wrote the text', () {
      expect(errorCopyFor(xhs.code).action, ErrorAction.goLogin);
      expect(errorCopyFor(ig.code).action, ErrorAction.goLogin);
      // The engine's message is what the user reads; the App copy is only a fallback.
      expect(displayErrorMessage(xhs.code, xhs.message), xhs.message);
      expect(displayErrorMessage(ig.code, ig.message), ig.message);
    });

    testWidgets('the error card offers only 去登录 and reports goLogin', (tester) async {
      expect(await pumpErrorCard(tester, xhs), [ErrorAction.goLogin]);
      expect(find.text('重试'), findsNothing);
    });

    testWidgets('the same holds for Instagram', (tester) async {
      expect(await pumpErrorCard(tester, ig), [ErrorAction.goLogin]);
    });

    test('a failed parse produces no outcome, so nothing is cached or recorded', () {
      expect(
        () => validateParserResult(xhs.asResult, SiteRegistry.current.byId('xhs')!),
        throwsA(isA<ParseFailure>().having((e) => e.code, 'code', 'LOGIN_REQUIRED')),
      );
      expect(
        () => validateParserResult(ig.asResult, SiteRegistry.current.byId('instagram')!),
        throwsA(isA<ParseFailure>().having((e) => e.code, 'code', 'LOGIN_REQUIRED')),
      );
    });
  });

  group('a post that really is gone keeps the old answer', () {
    late HookRun xhs;
    late HookRun ig;

    setUpAll(() async {
      xhs = await runHook('xhs', 'xhs/xhs_note_deleted.html', _xhsUrl, 'classify',
          loggedIn: true,
          errorCode: 'LOGIN_REQUIRED',
          errorMessage: 'Xiaohongshu returned an authenticated-only shell without note data.');
      ig = await runHook('instagram', 'instagram/ig_post_deleted.html', _igDeletedUrl, 'classify',
          loggedIn: true,
          errorCode: 'LOGIN_REQUIRED',
          errorMessage: 'Instagram returned a login-gated shell without post data.');
    });

    test('the platform notice wins over the login wall', () {
      expect(xhs.code, 'PRIVATE_OR_UNAVAILABLE');
      expect(xhs.message, contains('分享链接可能已过期'));
      expect(ig.code, 'PRIVATE_OR_UNAVAILABLE');
      expect(ig.message, '未能读取帖子内容（可能包含受限内容或已被删除）');
    });

    test('the copy still goes back home and the engine text is shown', () {
      expect(errorCopyFor(xhs.code).action, ErrorAction.backHome);
      expect(errorCopyFor(ig.code).action, ErrorAction.backHome);
      expect(displayErrorMessage(ig.code, ig.message), ig.message);
    });

    testWidgets('the card offers 返回首页, never 去登录', (tester) async {
      expect(await pumpErrorCard(tester, xhs), [ErrorAction.backHome]);
      expect(find.text('去登录'), findsNothing);
    });

    test('neither case reaches a saved record', () {
      expect(
        () => validateParserResult(xhs.asResult, SiteRegistry.current.byId('xhs')!),
        throwsA(isA<ParseFailure>().having((e) => e.code, 'code', 'PRIVATE_OR_UNAVAILABLE')),
      );
    });
  });

  group('the parser now hands out the full-quality JPEG candidate', () {
    late HookRun multi;
    late HookRun live;

    setUpAll(() async {
      multi = await runHook('xhs', 'xhs/xhs_multi.html', _xhsUrl, 'parsePage');
      live = await runHook('xhs', 'xhs/xhs_live.html', _xhsLiveUrl, 'parsePage');
    });

    /// The planned files of one item, built by the installed App itself.
    List<PlannedFile> planOf(HookRun run, int index) {
      final post = ParsedPost.fromJson(run.data);
      return planFiles(post, [index], (label, seq, ext) => '${label}_$seq.$ext');
    }

    /// Every candidate the App will request, validated by the request policy.
    void expectPolicyAllows(HookRun run, PlannedFile file) {
      final item = MediaItem.fromJson(run.items[file.itemIndex - 1]);
      final policy = MediaRequestPolicy(SiteRegistry.current.byId('xhs')!);
      final declared = policy.resourcesFor(item);
      for (final url in file.urls) {
        expect(
          declared.map((resource) => resource.url),
          contains(url),
          reason: 'the parser must declare every candidate it hands out: $url',
        );
      }
    }

    test('the item itself lists it first and keeps the original as the item URL', () {
      for (final item in multi.items) {
        final fallbacks = (item['fallbacks'] as List).cast<String>();
        expect(fallbacks.first, '${item['url']}?imageView2/format/jpg/q/100');
        expect((item['downloadOrder'] as List).first, fallbacks.first);
      }
    });

    test('the planned still asks for it first, once, and before the original', () {
      final file = planOf(multi, 0).single;
      final urls = file.urls;
      expect(urls.toSet(), hasLength(urls.length), reason: 'no URL may be queued twice');
      expect(urls.first, '${multi.items[0]['url']}?imageView2/format/jpg/q/100');
      expect(urls, contains(multi.items[0]['url']));
      expect(urls.where((url) => url == multi.items[0]['url']), hasLength(1));
      expect(urls.indexOf(multi.items[0]['url']), lessThan(urls.length - 1),
          reason: 'the stored original is still tried before falling back to a default-size copy');
      expectPolicyAllows(multi, file);
    });

    test('every still of the post is planned the same way', () {
      final files = planFiles(
        ParsedPost.fromJson(multi.data),
        List<int>.generate(multi.items.length, (i) => i),
        (label, seq, ext) => '${label}_$seq.$ext',
      );
      for (final file in files) {
        expect(file.urls.toSet(), hasLength(file.urls.length));
        expect(file.urls.first, contains('imageView2/format/jpg/q/100'));
        expectPolicyAllows(multi, file);
      }
    });

    test('a Live photo still gets it too and its clip stays separate', () {
      final files = planOf(live, 0);
      expect(files, hasLength(2));
      final still = files.firstWhere((file) => file.isImage);
      expect(still.urls.toSet(), hasLength(still.urls.length));
      expect(still.urls.first, '${live.items[0]['url']}?imageView2/format/jpg/q/100');
      final clip = files.firstWhere((file) => !file.isImage);
      expect(clip.urls, [live.items[0]['videoUrl']]);
      expect(still.urls, isNot(contains(live.items[0]['videoUrl'])));
      expectPolicyAllows(live, still);
    });
  });

  // The device report that holds this release back: after signing out of
  // Xiaohongshu the App parsed a note link, the WebView was sent to `/explore`,
  // and the hook answered nothing at all — the App then showed
  // `FormatException: Invalid parser hook result` with nothing but 重试.
  group('a note link Xiaohongshu redirects to the home feed', () {
    late HookRun parsePage;
    late HookRun signedOut;
    late HookRun sessionGone;

    setUpAll(() async {
      // The device flow: parsePage on the page the WebView actually landed on,
      // then classify with the App's own signed-in state.
      parsePage = await runHook(
          'xhs', 'xhs/xhs_redirected_home.html', _xhsLandingUrl, 'parsePage');
      signedOut = await runHook(
          'xhs', 'xhs/xhs_redirected_home.html', _xhsLandingUrl, 'classify',
          loggedIn: false, errorCode: parsePage.code, errorMessage: parsePage.message);
      sessionGone = await runHook(
          'xhs', 'xhs/xhs_redirected_home.html', _xhsLandingUrl, 'classify',
          loggedIn: true, errorCode: parsePage.code, errorMessage: parsePage.message);
    });

    test('the landing page never answers nothing: LOGIN_REQUIRED, not an exception', () {
      expect(parsePage.value['ok'], false);
      expect(parsePage.code, 'LOGIN_REQUIRED');
      expect(parsePage.message, '需要先登录小红书才能解析该笔记');
    });

    test('signed out the App asks for a login; signed in it reports the dead session', () {
      expect(signedOut.code, 'LOGIN_REQUIRED');
      expect(signedOut.message, '需要先登录小红书才能解析该笔记');
      expect(sessionGone.code, 'LOGIN_REQUIRED');
      expect(sessionGone.message, '登录可能已失效，请重新登录');
      for (final run in [signedOut, sessionGone]) {
        expect(errorCopyFor(run.code).action, ErrorAction.goLogin);
        expect(displayErrorMessage(run.code, run.message), run.message);
      }
    });

    test('the installed App fails the parse with that code, not a FormatException', () {
      for (final run in [signedOut, sessionGone]) {
        expect(
          () => validateParserResult(run.asResult, SiteRegistry.current.byId('xhs')!),
          throwsA(isA<ParseFailure>()
              .having((e) => e.code, 'code', 'LOGIN_REQUIRED')
              .having((e) => e.message, 'message', run.message)),
          reason: '${run.code}/${run.message}',
        );
      }
    });

    testWidgets('the error card offers 去登录 only', (tester) async {
      expect(await pumpErrorCard(tester, signedOut), [ErrorAction.goLogin]);
      expect(find.text('重试'), findsNothing);
    });

    test('a document being replaced is INVALID_PAGE, never a null hook result', () async {
      for (final doc in ['missing', 'throwing']) {
        final run = await runHook(
            'xhs', 'xhs/xhs_redirected_home.html', _xhsUrl, 'parsePage', doc: doc);
        expect(run.code, 'INVALID_PAGE', reason: doc);
        expect(run.message, '页面内容无法识别，可能已改版', reason: doc);
        expect(
          () => validateParserResult(run.asResult, SiteRegistry.current.byId('xhs')!),
          throwsA(isA<ParseFailure>().having((e) => e.code, 'code', 'INVALID_PAGE')),
          reason: doc,
        );
      }
      expect(errorCopyFor('INVALID_PAGE').action, ErrorAction.retry);
    });
  });
}
