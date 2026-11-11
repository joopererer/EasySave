import 'package:easysave/core/models.dart';
import 'package:easysave/pages/preview_page.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/preview_route_observer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:async';

void main() {
  testWidgets('all preview openers reuse a post underneath another page', (tester) async {
    final observer = PreviewRouteObserver.instance..reset();
    HistoryDb.setOpeningForTesting(Completer<HistoryDb>().future);
    await tester.pumpWidget(MaterialApp(navigatorObservers: [observer],
        home: const Scaffold(body: Text('Home'))));
    final context = tester.element(find.text('Home'));
    final post = ParsedPost(platform: 'instagram', id: 'ReusePost',
        url: 'https://www.instagram.com/p/ReusePost/', author: PostAuthor(), items: []);
    final first = PreviewPage.open(context, post: post);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('Other'))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await PreviewPage.open(context, post: post);
    await tester.pumpAndSettle();
    expect(observer.depth, 2);
    expect(find.byType(PreviewPage), findsOneWidget);
    expect(find.text('Other'), findsNothing);
    Navigator.of(context).pop();
    await first;
    await tester.pumpWidget(const SizedBox.shrink());
    HistoryDb.resetInstanceForTesting();
    observer.reset();
  });
}
