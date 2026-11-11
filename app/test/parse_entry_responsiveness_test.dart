import 'dart:async';

import 'package:easysave/pages/parse_page.dart';
import 'package:easysave/pages/preview_page.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/preview_route_observer.dart';
import 'package:easysave/services/shared_preview_cache.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _PreviewPushCounter extends NavigatorObserver {
  int previews = 0;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route.settings.name == kPreviewRouteName) previews++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const link = 'https://www.instagram.com/p/EntryLatency123/';
  late Completer<HistoryDb> history;
  late HistoryDb ready;
  late int lookups;
  late Completer<void> cacheProbe;
  var holdCacheProbe = false;
  setUpAll(sqfliteFfiInit);
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    HistoryDb.resetInstanceForTesting();
    PreviewRouteObserver.instance.reset();
    databaseFactory = databaseFactoryFfi;
    ready = await HistoryDb.instance(dbPath: ':memory:');
    history = Completer<HistoryDb>();
    HistoryDb.setOpeningForTesting(history.future);
    lookups = 0;
    cacheProbe = Completer<void>();
    holdCacheProbe = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(sharedPreviewChannel, (call) async {
          if (call.method == 'lookupParsed') {
            lookups++;
            if (holdCacheProbe) await cacheProbe.future;
            return {
              'status': 'hit',
              'value': {
                'expires': DateTime.now().add(const Duration(minutes: 5)).millisecondsSinceEpoch,
                'post': {
                  'platform': 'instagram',
                  'id': 'EntryLatency123',
                  'url': link,
                  'author': <String, Object?>{},
                  'items': [
                    {'type': 'image', 'url': 'https://scontent.cdninstagram.com/original.jpg'},
                  ],
                },
                'rawImages': [],
              },
            };
          }
          if (call.method == 'thumbnailPrefetchAllowed') return false;
          if (call.method == 'thumbnailAcquire') return true;
          if (call.method == 'thumbnailRead') return Completer<String?>().future;
          return null;
        });
  });
  tearDown(() {
    if (!history.isCompleted) history.complete(ready);
    if (!cacheProbe.isCompleted) cacheProbe.complete();
    databaseFactory = databaseFactoryFfi;
    HistoryDb.resetInstanceForTesting();
    PreviewRouteObserver.instance.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(sharedPreviewChannel, null);
  });

  Future<_PreviewPushCounter> showEntry(WidgetTester tester) async {
    final observer = _PreviewPushCounter();
    await tester.pumpWidget(MaterialApp(
      navigatorObservers: [PreviewRouteObserver.instance, observer],
      home: const ParsePage(initializeServices: false),
    ));
    await tester.enterText(find.byType(TextField), link);
    return observer;
  }

  testWidgets('parse button shows progress before slow history preparation finishes', (tester) async {
    holdCacheProbe = true;
    await showEntry(tester);
    try {
      await tester.tap(find.text('解析'));
      await tester.pump();
      expect(history.isCompleted, isFalse);
      expect(find.text('解析中…'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('five rapid parse taps claim one operation and push exactly one preview', (tester) async {
    final observer = await showEntry(tester);
    try {
      for (var i = 0; i < 5; i++) {
        await tester.tap(find.text('解析'));
      }
      await tester.pump();
      expect(history.isCompleted, isFalse);
      history.complete(ready);
      // FFI replies arrive on a real isolate, outside WidgetTester's fake
      // clock. Drain each SQL round trip without a wall-clock latency bound.
      for (var i = 0; i < 10; i++) {
        await tester.pump();
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 25));
        });
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(lookups, 1);
      expect(observer.previews, 1);
      expect(find.byType(PreviewPage), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('shared RAM cache opens preview within 300ms while history stays blocked', (tester) async {
    final observer = await showEntry(tester);
    try {
      await tester.tap(find.text('解析'));
      await tester.pump();
      // Logical time is controlled by WidgetTester: no hardware stopwatch or
      // network performance assertion can make this regression flaky.
      await tester.pump(const Duration(milliseconds: 250));
      expect(history.isCompleted, isFalse);
      expect(lookups, 1);
      expect(observer.previews, 1);
      expect(find.byType(PreviewPage), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}
