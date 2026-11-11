import 'dart:convert';
import 'package:easysave/pages/history_page.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:easysave/services/backup/backup_service.dart';
import 'package:easysave/metadata/url_normalizer.dart';
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
  tearDown(SiteRegistry.useBuiltin);
  test(
    'registry resolves ids, platform names and aliases without merging unknown sites',
    () {
      expect(SiteRegistry.current.sameSite('xhs', 'xiaohongshu'), isTrue);
      expect(SiteRegistry.current.canonicalId('rednote'), 'xhs');
      expect(SiteRegistry.current.canonicalId('twitter'), 'x');
      expect(toSpecPlatform('xiaohongshu'), 'xiaohongshu');
      expect(toSpecPlatform('xhs'), 'xiaohongshu');
      expect(toSpecPlatform('twitter'), 'x');
      expect(SiteRegistry.current.sameSite('unknown_a', 'unknown_b'), isFalse);
      SiteRegistry.activate([]);
      expect(SiteRegistry.current.sameSite('xhs', 'xiaohongshu'), isTrue);
      expect(toSpecPlatform('rednote'), 'xiaohongshu');
    },
  );
  testWidgets(
    'real posts menu has one XHS choice and selects both legacy platform values',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      HistoryDb.resetInstanceForTesting();
      late HistoryDb db;
      await tester.runAsync(() async {
        db = await HistoryDb.instance(dbPath: ':memory:');
        HistoryDb.setInstanceForTesting(db);
        for (final (platform, id, title) in [
          ('xhs', 'aaa111', 'legacy key'),
          ('xiaohongshu', 'bbb222', 'platform name'),
          ('x', 'ccc333', 'other site'),
        ]) {
          await db.upsert(
            HistoryRecord(
              platform: platform,
              postId: id,
              postUrl: 'https://www.xiaohongshu.com/explore/$id',
              title: title,
              fileCount: 0,
              createdAt: DateTime(2026),
            ),
          );
        }
        final exported =
            jsonDecode(await BackupService.exportBackup(db: db)) as Map;
        expect(
          (exported['posts'] as List).where(
            (p) => p['platform'] == 'xiaohongshu',
          ),
          hasLength(2),
        );
        expect((await db.getByPostId('aaa111'))!.platform, 'xhs');
        expect((await db.getByPostId('bbb222'))!.platform, 'xiaohongshu');
      });
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('com.fluttercandies/photo_manager'),
        (_) async => 0,
      );
      await tester.pumpWidget(const MaterialApp(home: HistoryPage()));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('canonical-platform-filter')));
      await tester.pumpAndSettle();
      final xhsOption = find.descendant(
        of: find.byType(PopupMenuItem<String>),
        matching: find.text('小红书'),
      );
      expect(xhsOption, findsOneWidget);
      await tester.tap(xhsOption);
      await tester.pumpAndSettle();
      expect(find.text('legacy key'), findsOneWidget);
      expect(find.text('platform name'), findsOneWidget);
      expect(find.text('other site'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        expect((await db.getByPostId('aaa111'))!.platform, 'xhs');
        expect((await db.getByPostId('bbb222'))!.platform, 'xiaohongshu');
      });
      HistoryDb.resetInstanceForTesting();
      messenger.setMockMethodCallHandler(
        const MethodChannel('com.fluttercandies/photo_manager'),
        null,
      );
    },
  );
}
