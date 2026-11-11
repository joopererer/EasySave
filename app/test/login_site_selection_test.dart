import 'package:easysave/pages/login_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

class _LoginPlatform extends InAppWebViewPlatform {
  PlatformInAppWebViewWidgetCreationParams? created;
  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) {
    created = params;
    return _LoginView(params);
  }
}

class _LoginView extends PlatformInAppWebViewWidget {
  _LoginView(super.params) : super.implementation();
  @override
  Widget build(BuildContext context) => const SizedBox();
  @override
  void dispose() {}
  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) =>
      throw UnimplementedError();
}

void main() {
  testWidgets(
    'mainland choice renders desktop shared WebView and QR instructions',
    (tester) async {
      final platform = _LoginPlatform();
      InAppWebViewPlatform.instance = platform;
      await tester.pumpWidget(
        const MaterialApp(home: LoginPage(platform: 'xhs')),
      );
      await tester.tap(find.text('小红书（中国大陆账号）'));
      await tester.pump();
      final params = platform.created!;
      expect(
        params.initialUrlRequest!.url.toString(),
        'https://www.xiaohongshu.com/login',
      );
      expect(params.initialSettings!.userAgent, isNot(contains('Mobile')));
      expect(
        params.initialSettings!.preferredContentMode,
        UserPreferredContentMode.DESKTOP,
      );
      expect(params.initialSettings!.sharedCookiesEnabled, isTrue);
      expect(find.textContaining('扫一扫 → 从相册选择'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('generic XHS login offers both domains before opening WebView', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: LoginPage(platform: 'xhs')),
    );
    expect(find.text('小红书（中国大陆账号）'), findsOneWidget);
    expect(find.text('rednote（海外账号）'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
