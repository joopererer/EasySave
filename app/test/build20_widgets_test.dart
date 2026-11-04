import 'package:easysave/pages/parse_page.dart';
import 'package:easysave/pages/mine_page.dart';
import 'package:easysave/services/auth.dart';
import 'package:easysave/widgets/shared.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('real ParsePage shows clear only for non-empty input', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: ParsePage(initializeServices: false)),
    );
    expect(find.byKey(const ValueKey('clear-link-input')), findsNothing);
    await tester.enterText(find.byType(TextField), 'synthetic link');
    await tester.pump();
    expect(find.byTooltip('清空链接'), findsOneWidget);
    await tester.tap(find.byTooltip('清空链接'));
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    expect(find.byTooltip('清空链接'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'real MinePage confirms log clearing and cancellation does not clear',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      PackageInfo.setMockInitialValues(
        appName: 'EasySave',
        packageName: 'com.james.easysave',
        version: '1.10.0',
        buildNumber: '20',
        buildSignature: '',
      );
      final calls = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('easysave/bubble'),
        (call) async => false,
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('easysave/dev_log'),
        (call) async {
          calls.add(call.method);
          return null;
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: MinePage(
            xhsSessionProbe: ({String entry = 'test'}) async =>
                SessionStatus.invalid,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('清空日志'),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.text('清空日志'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清空日志'));
      await tester.pumpAndSettle();
      expect(find.textContaining('不会退出账号'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(calls, isNot(contains('clear')));
      await tester.tap(find.text('清空日志'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认清空'));
      await tester.pumpAndSettle();
      expect(calls.where((call) => call == 'clear'), hasLength(1));
      expect(find.text('日志已清空'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      messenger.setMockMethodCallHandler(
        const MethodChannel('easysave/dev_log'),
        null,
      );
    },
  );
  testWidgets('real PlatformTag renders all four bundled brand vectors', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              PlatformTag(platform: 'xhs'),
              PlatformTag(platform: 'instagram'),
              PlatformTag(platform: 'x'),
              PlatformTag(platform: 'tiktok'),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SvgPicture), findsNWidgets(4));
    expect(find.byIcon(Icons.menu_book), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
