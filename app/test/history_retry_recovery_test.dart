import 'dart:async';
import 'dart:io';

import 'package:easysave/pages/history_page.dart';
import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  testWidgets('HistoryPage retry starts a fresh database read after timed-out open', (tester) async {
    SharedPreferences.setMockInitialValues({});
    HistoryDb.resetInstanceForTesting();
    GalleryLocatorService.instance.resetForTesting();
    databaseFactory = databaseFactoryFfi;
    late String originalPath;
    final directory = Directory('build/v1410/history-retry')
      ..createSync(recursive: true);
    await tester.runAsync(() async {
      originalPath = await databaseFactoryFfi.getDatabasesPath();
      await databaseFactoryFfi.setDatabasesPath(directory.absolute.path);
    });
    final opening = Completer<HistoryDb>();
    HistoryDb.setOpeningForTesting(opening.future);
    const photos = MethodChannel('com.fluttercandies/photo_manager');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(photos, (_) async => 0);
    try {
      await tester.pumpWidget(const MaterialApp(home: HistoryPage()));
      await tester.pump();
      await tester.pump(const Duration(seconds: 6));
      await tester.pump();
      expect(find.text('重试'), findsOneWidget);
      expect(opening.isCompleted, isFalse);
      // Storage becomes available. The pending first native operation never
      // answers, so retry must not reuse the poisoned singleton future.
      await tester.tap(find.text('重试'));
      for (var i = 0; i < 20; i++) {
        await tester.pump();
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        });
      }
      await tester.pump();
      expect(opening.isCompleted, isFalse);
      expect(find.textContaining('记录读取失败'), findsNothing);
      expect(find.text('还没有下载记录，去首页解析第一条帖子吧'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(photos, null);
      GalleryLocatorService.instance.resetForTesting();
      HistoryDb.resetInstanceForTesting();
      await tester.runAsync(() => databaseFactoryFfi.setDatabasesPath(originalPath));
      databaseFactory = databaseFactoryFfi;
    }
  });

  testWidgets('HistoryPage clears an old refresh error after retry reads existing records', (tester) async {
    SharedPreferences.setMockInitialValues({});
    databaseFactory = databaseFactoryFfi;
    HistoryDb.resetInstanceForTesting();
    GalleryLocatorService.instance.resetForTesting();
    late HistoryDb ready;
    await tester.runAsync(() async {
      ready = await HistoryDb.instance(dbPath: ':memory:');
      await ready.upsert(HistoryRecord(
        platform: 'instagram',
        postId: 'history-error-recovery',
        postUrl: 'https://www.instagram.com/p/HistoryErrorRecovery/',
        title: 'Saved after retry',
        fileCount: 0,
        createdAt: DateTime(2026),
      ));
      HistoryDb.setInstanceForTesting(ready);
    });
    const photos = MethodChannel('com.fluttercandies/photo_manager');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(photos, (_) async => 0);
    try {
      await tester.pumpWidget(const MaterialApp(home: HistoryPage()));
      for (var i = 0; i < 10; i++) {
        await tester.pump();
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        });
      }
      await tester.pump();
      expect(find.text('Saved after retry'), findsOneWidget);
      final hung = Completer<HistoryDb>();
      HistoryDb.setOpeningForTesting(hung.future);
      final refresh = tester.state<HistoryPageState>(find.byType(HistoryPage)).reload();
      await tester.pump(const Duration(seconds: 6));
      await tester.pump();
      await refresh;
      expect(find.textContaining('记录读取失败'), findsOneWidget);
      // Retry has a healthy data source. Existing records mean this refresh is
      // silent; success must still clear the prior error rendered by the page.
      HistoryDb.setInstanceForTesting(ready);
      await tester.tap(find.text('重试'));
      for (var i = 0; i < 10; i++) {
        await tester.pump();
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        });
      }
      await tester.pump();
      expect(find.textContaining('记录读取失败'), findsNothing);
      expect(find.text('Saved after retry'), findsOneWidget);
      expect(hung.isCompleted, isFalse);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(photos, null);
      GalleryLocatorService.instance.resetForTesting();
      HistoryDb.resetInstanceForTesting();
    }
  });
}
