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
    expect(find.text('小红书（中国大陆账号）'), findsOneWidget);
    expect(find.text('rednote（海外账号）'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
