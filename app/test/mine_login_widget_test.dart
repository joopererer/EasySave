import 'package:easysave/pages/mine_page.dart';
import 'package:easysave/services/auth.dart';
import 'package:easysave/widgets/xhs_login_choices.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'EasySave',
      packageName: 'com.james.easysave',
      version: '1.10.0',
      buildNumber: '19',
      buildSignature: '',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('easysave/bubble'),
          (call) async => false,
        );
  });

  testWidgets('real MinePage opens the mainland and overseas account dialog', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MinePage(
          xhsSessionProbe: ({String entry = 'test'}) async =>
              SessionStatus.invalid,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('我的'), findsOneWidget);
    final xhsRow = find.ancestor(
      of: find.text('小红书'),
      matching: find.byType(ListTile),
    );
    await tester.tap(find.descendant(of: xhsRow, matching: find.text('去登录')));
    await tester.pumpAndSettle();
    expect(find.byType(SimpleDialog), findsOneWidget);
    expect(find.text('小红书（中国大陆账号）'), findsOneWidget);
    expect(find.text('rednote（海外账号）'), findsOneWidget);
    expect(find.textContaining('扫一扫 → 从相册选择'), findsOneWidget);
    expect(find.text('Rednote 登录'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'rendered login choices send each selected origin to the caller',
    (tester) async {
      String? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: XhsLoginChoices(onSelected: (value) => selected = value),
          ),
        ),
      );
      await tester.tap(find.text('小红书（中国大陆账号）'));
      expect(selected, 'https://www.xiaohongshu.com/login');
      await tester.tap(find.text('rednote（海外账号）'));
      expect(selected, 'https://www.rednote.com/explore');
    },
  );
}
