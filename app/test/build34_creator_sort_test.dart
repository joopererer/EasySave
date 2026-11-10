// v1.10 build 34 / problem 3: the history "按作者" view can be ordered by post
// count, by the author's most recent save, or by name (system locale
// collation, pinyin for Chinese), each ascending or descending, remembered
// locally.

import 'dart:convert';

import 'package:easysave/pages/history_page.dart';
import 'package:easysave/services/creator_sort.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/settings.dart';
import 'package:easysave/services/system_collation.dart';
import 'package:easysave/widgets/history_cards.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

CreatorSortRow _row(String id, String name, int posts, DateTime at) =>
    CreatorSortRow(id: id, name: name, postCount: posts, lastSavedAt: at);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  final rows = [
    _row('xhs:zhang', '张三', 1, DateTime(2026, 1, 3)),
    _row('xhs:li', '李四', 3, DateTime(2026, 1, 1)),
    _row('xhs:alice', 'Alice', 2, DateTime(2026, 1, 2)),
  ];
  // Pinyin order keys as the system collation would return them.
  const keys = {
    '张三': 'c',
    '李四': 'b',
    'Alice': 'a',
  };

  List<String> names(List<CreatorSortRow> list) =>
      [for (final row in list) row.name];

  test('post count, most recent save and name sort in both directions', () {
    expect(
      names(sortCreatorRows(rows,
          key: CreatorSortKey.recentSaved, descending: true)),
      ['张三', 'Alice', '李四'],
    );
    expect(
      names(sortCreatorRows(rows,
          key: CreatorSortKey.recentSaved, descending: false)),
      ['李四', 'Alice', '张三'],
    );
    expect(
      names(sortCreatorRows(rows,
          key: CreatorSortKey.postCount, descending: true)),
      ['李四', 'Alice', '张三'],
    );
    expect(
      names(sortCreatorRows(rows,
          key: CreatorSortKey.postCount, descending: false)),
      ['张三', 'Alice', '李四'],
    );
    expect(
      names(sortCreatorRows(rows,
          key: CreatorSortKey.name,
          descending: false,
          collationKeys: keys)),
      ['Alice', '李四', '张三'],
      reason: 'pinyin: a < li < zhang',
    );
    expect(
      names(sortCreatorRows(rows,
          key: CreatorSortKey.name,
          descending: true,
          collationKeys: keys)),
      ['张三', '李四', 'Alice'],
    );
    // Without collation keys the fallback is the lower-cased name, which is
    // still deterministic.
    expect(
      names(sortCreatorRows(rows,
          key: CreatorSortKey.name, descending: false)),
      isNot(['张三', '李四', 'Alice']),
    );
  });

  test('equal names fall back to the post count, then the latest save', () {
    final same = [
      _row('xhs:a', '小明', 2, DateTime(2026, 1, 1)),
      _row('xhs:b', '小明', 5, DateTime(2026, 1, 1)),
      _row('xhs:c', '小明', 2, DateTime(2026, 1, 5)),
    ];
    final sorted = sortCreatorRows(same,
        key: CreatorSortKey.name, descending: false);
    expect([for (final row in sorted) row.id], ['xhs:b', 'xhs:c', 'xhs:a']);
    // The order is stable for repeated calls and for equal data.
    expect(
      [for (final row in sortCreatorRows(same,
          key: CreatorSortKey.name, descending: false)) row.id],
      ['xhs:b', 'xhs:c', 'xhs:a'],
    );
  });

  test('a creator with no located file still gets a deterministic place', () {
    final list = [
      _row('xhs:none', '无文件', 1, DateTime(0)),
      _row('xhs:some', '有文件', 1, DateTime(2026, 1, 1)),
    ];
    expect(
      names(sortCreatorRows(list,
          key: CreatorSortKey.recentSaved, descending: true)),
      ['有文件', '无文件'],
    );
  });

  testWidgets('the creators view remembers its ordering', (tester) async {
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    HistoryDb.resetInstanceForTesting();
    GalleryLocatorService.instance.resetForTesting();
    DownloadManager.instance.clearBatchesForTesting();
    const photos = MethodChannel('com.fluttercandies/photo_manager');
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(photos, (_) async => 0);
    // Pinyin collation, as the native channel would answer on a zh device.
    SystemCollation.readerForTesting = (names) async => [
          for (final name in names) keys[name] ?? name.toLowerCase(),
        ];
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(photos, null);
      SystemCollation.readerForTesting = null;
      GalleryLocatorService.instance.resetForTesting();
      HistoryDb.resetInstanceForTesting();
      DownloadManager.instance.clearBatchesForTesting();
    });

    Future<void> save(String author, String slug, int postCount, DateTime at) async {
      final db = await HistoryDb.instance();
      for (var p = 1; p <= postCount; p++) {
        final id = '$slug$p';
        await db.upsert(HistoryRecord(
          platform: 'xhs',
          postId: id,
          postUrl: 'https://www.xiaohongshu.com/explore/$id',
          title: '$author post $id',
          authorName: author,
          fileCount: 1,
          createdAt: at,
          itemsJson: jsonEncode([
            {'type': 'image', 'url': 'https://img.example/$id.jpg', 'width': 10, 'height': 20},
          ]),
          files: [
            HistoryFile(
              filename: '${id}_1.jpg',
              savedAt: at.millisecondsSinceEpoch,
              itemIndex: 1,
              mediaId: '${id}_1',
              status: FileStatus.found,
            ),
          ],
        ));
      }
    }

    await tester.runAsync(() async {
      final db = await HistoryDb.instance(dbPath: ':memory:');
      HistoryDb.setInstanceForTesting(db);
      await db.clear();
      await save('张三', 'zhang', 1, DateTime(2026, 1, 5));
      await save('李四', 'li', 3, DateTime(2026, 1, 1));
      await save('Alice', 'alice', 2, DateTime(2026, 1, 3));
    });

    await tester.pumpWidget(const MaterialApp(home: HistoryPage()));
    Future<void> settle() async {
      for (var i = 0; i < 12; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
    }

    await settle();
    await tester.tap(find.text('创作者'));
    await tester.pumpAndSettle();

    List<String> order() => [
          for (final card in tester.widgetList<CreatorCard>(find.byType(CreatorCard)))
            card.authorName,
        ];
    expect(order(), ['张三', 'Alice', '李四'],
        reason: 'default: most recently saved first');

    // Switch to the post count, descending.
    await tester.tap(find.byKey(const ValueKey('creator-sort-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('帖子数').last);
    await tester.pumpAndSettle();
    expect(order(), ['李四', 'Alice', '张三']);

    // The direction toggle flips to ascending.
    await tester.tap(find.byKey(const ValueKey('creator-sort-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('倒序（点按改为正序）').last);
    await tester.pumpAndSettle();
    expect(order(), ['张三', 'Alice', '李四']);

    // Name ordering uses the locale collation keys (pinyin here).
    await tester.tap(find.byKey(const ValueKey('creator-sort-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('名字').last);
    await tester.pumpAndSettle();
    expect(order(), ['Alice', '李四', '张三']);

    // Remembered locally.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('creatorSort'), CreatorSortKey.name.name);
    expect(prefs.getBool('creatorSortDescending'), isFalse);
    final settings = await AppSettings.load();
    expect(settings.creatorSort, CreatorSortKey.name);
  });
}