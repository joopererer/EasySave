import 'package:easysave/pages/history_page.dart';
import 'package:easysave/services/auth.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/widgets/shared.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets('unknown site survives database, display and history filtering', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    HistoryDb.resetInstanceForTesting();
    const siteId = 'future_site';
    await tester.runAsync(() async {
      final db = await HistoryDb.instance(dbPath: ':memory:');
      HistoryDb.setInstanceForTesting(db);
      for (final site in [siteId, 'xhs']) {
        await db.upsert(
          HistoryRecord(
            platform: site,
            postId: 'post-$site',
            postUrl: 'https://example.invalid/$site',
            title: 'title-$site',
            fileCount: 1,
            createdAt: DateTime(2026),
          ),
        );
      }
      final stored = (await db.getByPostId('post-$siteId'))!;
      expect(stored.platform, siteId);
      expect(stored.toPost().platform, siteId);
      expect(platformFromKey(siteId), siteId);
      expect(platformLabel(siteId), siteId);
      expect((await db.getByPostId('post-xhs'))!.platform, 'xhs');
    });

    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('com.fluttercandies/photo_manager'),
      (call) async => 0,
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: PlatformTag(platform: siteId)),
      ),
    );
    expect(find.text(siteId), findsOneWidget);
    await tester.pumpWidget(const MaterialApp(home: HistoryPage()));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    expect(find.text('title-$siteId'), findsOneWidget);
    expect(find.text('title-xhs'), findsOneWidget);
    await tester.tap(find.byTooltip('平台筛选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(siteId).last);
    await tester.pumpAndSettle();
    expect(find.text('title-$siteId'), findsOneWidget);
    expect(find.text('title-xhs'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    HistoryDb.resetInstanceForTesting();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('com.fluttercandies/photo_manager'),
      null,
    );
  });
}
