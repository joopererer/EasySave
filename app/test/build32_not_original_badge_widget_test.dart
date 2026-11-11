import 'dart:convert';

import 'package:easysave/pages/history_page.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/services/history_db.dart';
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

  testWidgets('history marks a saved image that is not the original',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    HistoryDb.resetInstanceForTesting();
    GalleryLocatorService.instance.resetForTesting();
    DownloadManager.instance.clearBatchesForTesting();
    const photos = MethodChannel('com.fluttercandies/photo_manager');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(photos, (_) async => 0);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(photos, null);
      GalleryLocatorService.instance.resetForTesting();
      HistoryDb.resetInstanceForTesting();
    });
    await tester.runAsync(() async {
      final db = await HistoryDb.instance(dbPath: ':memory:');
      HistoryDb.setInstanceForTesting(db);
      await db.clear();
      await db.upsert(HistoryRecord(
        platform: 'xhs',
        postId: 'lowres-post',
        postUrl: 'https://www.xiaohongshu.com/explore/lowres-post',
        title: 'Low resolution',
        fileCount: 1,
        createdAt: DateTime.now(),
        itemsJson: jsonEncode([{'type': 'image', 'url': 'https://img.example/lowres.jpg', 'width': 1290, 'height': 1608}]),
        files: [
          HistoryFile(filename: 'lowres-post_1.jpg', savedAt: 1, itemIndex: 1,
              mediaId: '11', status: FileStatus.found, notOriginal: true),
        ],
      ));
    });
    await tester.pumpWidget(const MaterialApp(home: HistoryPage()));
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(find.text('Low resolution'), findsOneWidget);
    expect(find.text('非原图'), findsOneWidget);
  });
}
