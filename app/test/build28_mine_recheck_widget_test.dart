import 'dart:async';

import 'package:easysave/pages/mine_page.dart';
import 'package:easysave/services/auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('unknown login renders recheck and a pending check indicator', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'EasySave',
      packageName: 'com.james.easysave',
      version: '1.10.0',
      buildNumber: '28',
      buildSignature: '',
    );
    const channel = MethodChannel('easysave/bubble');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => false,
    );
    var checks = 0;
    final recheck = Completer<SessionStatus>();
    await tester.pumpWidget(
      MaterialApp(
        home: MinePage(
          xhsSessionProbe: ({String entry = 'test'}) async {
            checks++;
            return checks == 1 ? SessionStatus.unknown : recheck.future;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('重新检查'), findsOneWidget);
    await tester.tap(find.text('重新检查'));
    await tester.pump();
    final xhsRow = find.ancestor(
      of: find.text('小红书'),
      matching: find.byType(ListTile),
    );
    expect(
      find.descendant(of: xhsRow, matching: find.text('检查中…')),
      findsOneWidget,
    );
    expect(checks, 2);
    recheck.complete(SessionStatus.invalid);
    await tester.pumpAndSettle();
    expect(find.text('检查中…'), findsNothing);
    expect(find.text('重新检查'), findsNothing);
    expect(find.text('去登录'), findsWidgets);
    await tester.pumpWidget(const SizedBox.shrink());
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      null,
    );
  });
}
