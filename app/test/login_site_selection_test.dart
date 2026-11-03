import 'package:easysave/pages/login_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('generic XHS login offers both domains before opening WebView', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: LoginPage(platform: 'xhs')),
    );
    expect(find.text('小红书登录'), findsOneWidget);
    expect(find.text('Rednote 登录'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
