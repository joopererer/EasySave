// Copyright 2026 EasySave. All rights reserved.
// v1.12, Task 3: TikTok REGION_RESTRICTED copy and actions.

import 'package:easysave/core/error_copy.dart';
import 'package:easysave/core/models.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:easysave/widgets/shared.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SiteRegistry.useBuiltin();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(SiteRegistry.useBuiltin);

  group('TikTok REGION_RESTRICTED', () {
    test('provides specific region restriction copy and openUrl action', () {
      final copy = errorCopyFor(ParseErrorCode.regionRestricted);
      expect(copy.message, '该内容在你所在的地区不可用（平台限制），登录也无法查看');
      expect(copy.action, ErrorAction.openUrl);
    });

    test('displayErrorMessage always returns the region restriction copy', () {
      final msg = displayErrorMessage(
        ParseErrorCode.regionRestricted,
        '该 TikTok 帖子受地区或 IP 限制',
      );
      expect(msg, '该内容在你所在的地区不可用（平台限制），登录也无法查看');
    });

    testWidgets('ErrorCard for REGION_RESTRICTED shows 打开原链接 and NOT 去登录', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ErrorCard(
              code: ParseErrorCode.regionRestricted,
              canLogin: true,
              showLoginAction: false,
              onAction: (_) async {},
            ),
          ),
        ),
      );

      expect(find.text('该内容在你所在的地区不可用（平台限制），登录也无法查看'), findsOneWidget);
      expect(find.text('打开原链接'), findsOneWidget);
      expect(find.text('去登录'), findsNothing);
      expect(find.text('重试'), findsNothing);
    });
  });
}
