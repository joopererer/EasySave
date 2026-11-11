import 'dart:convert';

import 'package:easysave/pages/history_page.dart';
import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/media_delete_service.dart';
import 'package:easysave/widgets/gallery_browser.dart';
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
  testWidgets(
    'unbound inferred rows never become saved card or viewer entries',
    (tester) async {
      SharedPreferences.setMockInitialValues({'historyLayout': 'list'});
      HistoryDb.resetInstanceForTesting();
      GalleryLocatorService.instance.resetForTesting();
      const photos = MethodChannel('com.fluttercandies/photo_manager');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        photos,
        (_) async => 0,
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          photos,
          null,
        );
        GalleryLocatorService.instance.resetForTesting();
        HistoryDb.resetInstanceForTesting();
      });
      await tester.runAsync(() async {
        final db = await HistoryDb.instance(dbPath: ':memory:');
        HistoryDb.setInstanceForTesting(db);
        await db.clear();
        await db.upsert(
          HistoryRecord(
            platform: 'xhs',
            postId: 'unbound-post',
            postUrl: 'https://example.test/unbound-post',
            title: 'Unbound candidates',
            fileCount: 9,
            createdAt: DateTime(2026),
            itemsJson: jsonEncode([
              for (var index = 1; index <= 9; index++)
                {'type': 'image', 'url': 'https://img.example/$index.jpg'},
            ]),
            files: [
              for (var index = 1; index <= 9; index++)
                HistoryFile(
                  filename: 'unbound-post_$index.jpg',
                  savedAt: 1,
                  itemIndex: index,
                ),
            ],
          ),
        );
        final record = (await db.getByPostId('unbound-post'))!;
        expect(record.files, hasLength(9));
        expect(record.savedFiles, isEmpty);
        expect(deletableMediaFor([record]), isEmpty);
      });
      await tester.pumpWidget(const MaterialApp(home: HistoryPage()));
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(find.textContaining('0 个文件 ·'), findsOneWidget);
      expect(find.textContaining('9 个文件 ·'), findsNothing);
      await tester.tap(find.text('Unbound candidates'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(GalleryBrowserPage), findsNothing);
    },
  );
}
