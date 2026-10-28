import 'package:easysave/widgets/ai_label_badge.dart';
import 'package:easysave/widgets/shared.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('AI uses the platform tag height and typography', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Row(children: [
      PlatformTag(platform: 'tiktok'), AiLabelBadge(text: '原文', source: 'author'),
    ]))));
    expect(tester.getSize(find.byType(AiLabelBadge)).height,
        tester.getSize(find.byType(PlatformTag)).height);
    expect(tester.widget<Text>(find.text('AI')).style?.fontSize,
        tester.widget<Text>(find.text('TikTok')).style?.fontSize);
    await tester.tap(find.text('AI'));
    await tester.pumpAndSettle();
    expect(find.text('原文'), findsOneWidget);
    expect(find.text('作者声明'), findsOneWidget);
  });
}
