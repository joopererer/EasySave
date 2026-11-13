// v1.10.3 build 47 — the login card that outlived its login.
//
// Build 46: after a successful Instagram login the parse page still showed
// "未能获取图片，请检查 Instagram 登录后重试。[去登录]" until 解析 was tapped a
// second time. The card describes the state *before* the login, so a confirmed
// session has to clear it and re-parse the link on its own.

import 'package:easysave/core/error_copy.dart';
import 'package:easysave/core/models.dart';
import 'package:easysave/services/auth.dart';
import 'package:easysave/services/login_navigation.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:easysave/widgets/shared.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(SiteRegistry.useBuiltin);
  tearDown(SiteRegistry.useBuiltin);

  test('a login clears the card of the site it belongs to', () {
    expect(
      loginClearsErrorCard(
        errorPlatform: platformFromUrl('https://www.instagram.com/p/AbC123/'),
        loginPlatform: 'instagram',
      ),
      isTrue,
    );
    expect(
      loginClearsErrorCard(
        errorPlatform: platformFromUrl(
          'https://www.xiaohongshu.com/explore/6af1ad13000000003400572d',
        ),
        loginPlatform: 'xhs',
      ),
      isTrue,
    );
  });

  test('another site keeps its card', () {
    expect(
      loginClearsErrorCard(
        errorPlatform: platformFromUrl('https://www.instagram.com/p/AbC123/'),
        loginPlatform: 'xhs',
      ),
      isFalse,
    );
    expect(
      loginClearsErrorCard(
        errorPlatform: platformFromUrl('https://x.com/user/status/1'),
        loginPlatform: 'tiktok',
      ),
      isFalse,
    );
  });

  test('an unknown platform clears rather than strands the card', () {
    // The card can come from the background engine for a link the input no
    // longer holds; there is nothing to compare, and a card that cannot be
    // dismissed by logging in is worse than one cleared too eagerly.
    expect(
      loginClearsErrorCard(errorPlatform: null, loginPlatform: 'instagram'),
      isTrue,
    );
    expect(
      loginClearsErrorCard(errorPlatform: 'instagram', loginPlatform: null),
      isTrue,
    );
  });

  // Parser 1.4.16 answers MEDIA_UNAVAILABLE to an App without the capability,
  // while an expired session still answers LOGIN_REQUIRED. Both cards have to
  // send the user to the login page and be cleared by the login that follows.
  for (final code in [
    ParseErrorCode.mediaUnavailable,
    ParseErrorCode.loginRequired,
  ]) {
    group('after parsing answers $code', () {
      const link = 'https://www.instagram.com/reel/DflxolxpdHT/';

      test('the card routes to login and the login clears it', () {
        final copy = errorCopyFor(code);
        expect(copy.action, ErrorAction.goLogin, reason: code);
        expect(
          loginClearsErrorCard(
            errorPlatform: platformFromUrl(link),
            loginPlatform: 'instagram',
          ),
          isTrue,
          reason: code,
        );
        // Another site's login must not clear it.
        expect(
          loginClearsErrorCard(
            errorPlatform: platformFromUrl(link),
            loginPlatform: 'xhs',
          ),
          isFalse,
          reason: code,
        );
      });

      testWidgets('the card shows 去登录 and reports goLogin', (tester) async {
        final actions = <ErrorAction>[];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ErrorCard(
                code: code,
                onAction: (action) async => actions.add(action),
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        expect(find.text('去登录'), findsOneWidget, reason: code);
        await tester.tap(find.text('去登录'));
        await tester.pump();
        expect(actions, [ErrorAction.goLogin], reason: code);
      });
    });
  }
}
