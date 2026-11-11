import 'package:easysave/pages/history_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('fifty groups reach the last item without accumulating headers', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            controller: controller,
            slivers: [
              for (var i = 0; i < 50; i++)
                historyGroupSliver(
                  title: 'Author $i',
                  background: Colors.white,
                  content: SliverToBoxAdapter(
                    child: SizedBox(height: 100, child: Text('Item $i')),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    for (var i = 0; i < 50; i++) {
      controller.jumpTo(
        (i * 110.0).clamp(0, controller.position.maxScrollExtent),
      );
      await tester.pump();
      final pinned = find.byType(SliverPersistentHeader).evaluate().where((e) {
        final render = e.renderObject as RenderSliver;
        return render.geometry!.scrollExtent > 0 &&
            render.constraints.scrollOffset > 0 &&
            render.geometry!.paintExtent > 0;
      });
      expect(pinned.length, lessThanOrEqualTo(1));
    }
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pump();
    expect(find.text('Item 49'), findsOneWidget);
  });
}
