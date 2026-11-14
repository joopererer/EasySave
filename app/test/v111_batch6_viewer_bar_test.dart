// Copyright 2026 EasySave. All rights reserved.
// v1.11 batch 6: the bottom bar is driven by the selection.
//
// With nothing selected every button acts on the page in view; with a
// selection every button acts on all of them. Each button keeps its tooltip,
// semantics label and a corner badge with the number of selected items, and
// all of them share one 48 dp height.

import 'dart:io';

import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/widgets/gallery_browser.dart';
import 'package:easysave/widgets/verified_asset_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:share_plus_platform_interface/share_plus_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _postUrl = 'https://www.xiaohongshu.com/explore/2118566677374022101';

AssetEntity _asset(String id) => AssetEntity(
  id: id,
  typeInt: AssetType.image.index,
  width: 1080,
  height: 1440,
  title: '$id.jpg',
);

GalleryBrowserItem _item(int index,
        {bool missing = false, bool live = false, AssetEntity? asset}) =>
    GalleryBrowserItem(
      index: index,
      type: live ? 'live' : 'image',
      url: '',
      asset: missing ? null : (asset ?? _asset('$index')),
      missing: missing,
      status: missing ? FileStatus.notFound : FileStatus.found,
    );

class _LocalAsset extends AssetEntity {
  _LocalAsset({required String id, required this.path})
      : super(
          id: id,
          typeInt: AssetType.image.index,
          width: 1080,
          height: 1440,
          title: '$id.jpg',
        );

  final String path;

  @override
  Future<File?> get file async => File(path);
}

/// The page key of one item: `index:assetId`, or `index:missing`.
ValueKey<String> _pageKey(int index, {bool missing = false}) =>
    ValueKey<String>(missing ? '$index:missing' : '$index:$index');

List<GalleryBrowserItem> _items({
  bool missing = false,
  bool live = false,
}) => [
  for (var index = 0; index < 3; index++)
    _item(index,
        missing: missing && index == 1, live: live && index == 1),
];

enum _Mode { local, localWithMissing, remote }
final _FakeSharePlatform _sharePlatform = _FakeSharePlatform();

class _FakeSharePlatform extends SharePlatform {
  final List<ShareParams> calls = <ShareParams>[];

  @override
  Future<ShareResult> share(ShareParams params) async {
    calls.add(params);
    return const ShareResult('', ShareResultStatus.success);
  }
}

Future<void> _pumpViewer(
  WidgetTester tester, {
  required double width,
  required double textScale,
  _Mode mode = _Mode.local,
  List<GalleryBrowserItem>? items,
  void Function(int)? onDeleted,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = Size(width, 800);
  addTearDown(tester.view.reset);

  // A fresh state: a second pump of the same page would keep the old one.
  await tester.pumpWidget(const SizedBox.shrink());

  final local = mode != _Mode.remote;
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: Size(width, 800),
          textScaler: TextScaler.linear(textScale),
        ),
        child: GalleryBrowserPage(
          items: items ??
              _items(
                missing: mode == _Mode.localWithMissing,
                live: mode == _Mode.localWithMissing,
              ),
          originalTotal: 3,
          authorName: '作者名字',
          title: '一个足够长的标题用来占位',
          platform: 'xhs',
          postUrl: _postUrl,
          showSave: mode == _Mode.remote,
          onRedownloadItems: local ? (indices) async => null : null,
          onDeleteItem: local
              ? (item, {required bool deleteAlbumFiles}) async {
                  onDeleted?.call(item.index);
                  return GalleryBrowserItemDeletion(ok: true, undo: () async {});
                }
              : null,
          onReparse: local ? () {} : null,
        ),
      ),
    ),
  );
  await tester.pump();
}
int _badgeCount(WidgetTester tester, String key) {
  final badge = find.byKey(Key(key));
  if (badge.evaluate().isEmpty) return 0;
  final text = find.descendant(of: badge, matching: find.byType(Text)).first;
  return int.parse(tester.widget<Text>(text).data!);
}

Future<void> _tapCircle(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('browser_select_toggle')));
  await tester.pumpAndSettle();
}

Future<void> _swipeTo(WidgetTester tester, int page, double width) async {
  for (var i = 0; i < page; i++) {
    await tester.drag(find.byType(PageView), Offset(-width, 0));
    await tester.pumpAndSettle();
  }
}

Future<void> _selectPage(
  WidgetTester tester,
  int page,
  double width,
) async {
  await _swipeTo(tester, page, width);
  await _tapCircle(tester);
}

Future<void> _confirmDelete(WidgetTester tester, String title) async {
  expect(find.text('删除「$title」'), findsOneWidget);
  await tester.tap(find.text('仅删除记录'));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    VerifiedAssetImage.resetKnownPresentForTesting();
    GalleryLocatorService.instance
      ..resetForTesting()
      ..presenceProbeForTesting = (_) async => true;
    // SharePlus captures the platform once per process: keep one fake and
    // clear its calls between tests.
    SharePlatform.instance = _sharePlatform;
    _sharePlatform.calls.clear();
  });

  tearDown(() {
    GalleryLocatorService.instance.resetForTesting();
  });
  group('the bottom bar never overflows', () {
    for (final width in <double>[320, 360, 411]) {
      for (final scale in <double>[1.0, 1.3]) {
        for (final mode in _Mode.values) {
          testWidgets(
            '${width.toInt()} dp at $scale ${mode.name}',
            (tester) async {
              await _pumpViewer(
                tester,
                width: width,
                textScale: scale,
                mode: mode,
              );
              expect(
                tester.takeException(),
                isNull,
                reason: 'the bar must not overflow at $width dp / $scale',
              );

              // Every action reads as one line of one height.
              final finders = <Finder>[
                find.byKey(const Key('redownload')),
                find.byKey(const Key('delete_item')),
                find.byKey(const Key('share_item')),
                find.byKey(const Key('redownload_missing')),
                find.byKey(const Key('browser_more')),
                find.byKey(const Key('browser_primary_action')),
              ];
              for (final finder in finders) {
                final count = finder.evaluate().length;
                for (var i = 0; i < count; i++) {
                  expect(
                    tester.getRect(finder.at(i)).height,
                    inInclusiveRange(47.0, 49.0),
                    reason: 'every button is 48 dp high',
                  );
                }
              }

              final primary = find.byKey(
                Key(
                  mode == _Mode.remote
                      ? 'browser_primary_action'
                      : 'share_item',
                ),
              );
              expect(
                primary,
                findsOneWidget,
                reason: 'the primary action stays visible',
              );
              final rect = tester.getRect(primary);
              expect(rect.left, greaterThanOrEqualTo(0.0));
              expect(
                rect.right,
                lessThanOrEqualTo(width),
                reason: 'the primary action sits inside the screen',
              );

              if (mode == _Mode.localWithMissing) {
                // On the bar or folded into 「更多」, the missing items stay
                // reachable.
                final onBar = find.byKey(const Key('redownload_missing'));
                final inMenu = find.byKey(const Key('browser_more'));
                expect(
                  onBar.evaluate().isNotEmpty || inMenu.evaluate().isNotEmpty,
                  isTrue,
                );
              }

              // Let the 5 s thumbnail watchdogs of the pictures fire.
              await tester.pump(const Duration(seconds: 6));
              await tester.pumpWidget(const SizedBox.shrink());
            },
          );
        }
      }
    }
  });
  testWidgets('every action keeps its tooltip and semantics label', (
    tester,
  ) async {
    await _pumpViewer(
      tester,
      width: 411,
      textScale: 1.0,
      mode: _Mode.localWithMissing,
    );

    expect(find.byTooltip('重新下载'), findsOneWidget);
    expect(find.byTooltip('删除这张'), findsOneWidget);
    expect(find.byTooltip('分享'), findsOneWidget);
    expect(find.byTooltip('补下缺失的 1 张'), findsOneWidget);
    expect(find.byTooltip('更多操作'), findsOneWidget);

    final handle = tester.ensureSemantics();
    expect(find.bySemanticsLabel('重新下载'), findsWidgets);
    expect(find.bySemanticsLabel('删除这张'), findsWidgets);
    expect(find.bySemanticsLabel('分享'), findsWidgets);
    handle.dispose();

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the corner badge counts the selection', (tester) async {
    await _pumpViewer(tester, width: 411, textScale: 1.0, mode: _Mode.local);

    expect(find.byKey(const Key('badge_redownload')), findsNothing);

    // Entering multi-select from the circle badges every button.
    await _tapCircle(tester);
    expect(_badgeCount(tester, 'badge_redownload'), 1);
    expect(_badgeCount(tester, 'badge_delete'), 1);
    expect(_badgeCount(tester, 'badge_share'), 1);

    // Two pages, two selections.
    await _selectPage(tester, 1, 411);
    expect(_badgeCount(tester, 'badge_redownload'), 2);

    // Tapping the circle on a selected page clears one selection.
    await _tapCircle(tester);
    expect(_badgeCount(tester, 'badge_redownload'), 1);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('selecting every page keeps every item', (tester) async {
    await _pumpViewer(tester, width: 411, textScale: 1.0, mode: _Mode.local);
    await _selectPage(tester, 0, 411);
    await _selectPage(tester, 1, 411);
    await _selectPage(tester, 2, 411);
    expect(_badgeCount(tester, 'badge_redownload'), 3);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('deleting with no selection deletes the page in view', (
    tester,
  ) async {
    var deleted = <int>[];
    await _pumpViewer(
      tester,
      width: 411,
      textScale: 1.0,
      mode: _Mode.local,
      onDeleted: deleted.add,
    );
    await _swipeTo(tester, 1, 411);

    await tester.tap(find.byKey(const Key('delete_item')));
    await tester.pumpAndSettle();
    await _confirmDelete(tester, '第 2 项');
    expect(deleted, [1], reason: 'one item, by its original index');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('deleting with a selection deletes every selected item once', (
    tester,
  ) async {
    var deleted = <int>[];
    await _pumpViewer(
      tester,
      width: 411,
      textScale: 1.0,
      mode: _Mode.local,
      onDeleted: deleted.add,
    );
    await _selectPage(tester, 0, 411);
    await _selectPage(tester, 2, 411);

    await tester.tap(find.byKey(const Key('delete_item')));
    await tester.pumpAndSettle();
    await _confirmDelete(tester, '已选的 2 项');
    expect(deleted, [0, 2], reason: 'both selected items, each once');
    expect(find.text('1/1 (2/3)'), findsOneWidget);

    // Undo restores both in place.
    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect(find.text('3/3'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('sharing skips what is not on this device', (tester) async {
    final file = await tester.runAsync(() async {
      final made = File('${Directory.systemTemp.path}/easysave_b6_share.jpg');
      await made.writeAsBytes(const [1, 2, 3]);
      return made;
    });
    await _pumpViewer(
      tester,
      width: 411,
      textScale: 1.0,
      items: [
        _item(0, asset: _LocalAsset(id: '0', path: file!.path)),
        _item(1, missing: true),
        _item(2, asset: _LocalAsset(id: '2', path: file.path)),
      ],
    );
    await _selectPage(tester, 0, 411);
    await _selectPage(tester, 1, 411);
    await _selectPage(tester, 2, 411);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('share_item')));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('不在本机'), findsWidgets);
    final fake = _sharePlatform;
    expect(
      fake.calls.last.files?.length,
      2,
      reason: 'only the two files that still exist are shared',
    );
    expect(fake.calls.last.text, _postUrl);
    await tester.runAsync(() => file.delete());
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('sharing nothing on the device shares the post only', (
    tester,
  ) async {
    await _pumpViewer(
      tester,
      width: 411,
      textScale: 1.0,
      mode: _Mode.localWithMissing,
    );
    await _swipeTo(tester, 1, 411);
    await tester.tap(find.byKey(const Key('share_item')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final fake = _sharePlatform;
    expect(
      fake.calls.last.files ?? const <XFile>[],
      isEmpty,
      reason: 'the placeholder cannot be shared',
    );
    expect(fake.calls.last.text, _postUrl);
    await tester.pumpWidget(const SizedBox.shrink());
  });


  testWidgets('long pressing the picture enters multi-select', (
    tester,
  ) async {
    await _pumpViewer(tester, width: 411, textScale: 1.0, mode: _Mode.local);
    expect(find.byKey(const Key('badge_redownload')), findsNothing);

    await tester.longPress(find.byKey(_pageKey(0)));
    await tester.pumpAndSettle();
    expect(_badgeCount(tester, 'badge_redownload'), 1,
        reason: 'the still picture is selected');

    // Tapping the picture back out of selection clears one item.
    await tester.tap(find.byKey(_pageKey(0)));
    await tester.pumpAndSettle();
    expect(_badgeCount(tester, 'badge_redownload'), 0);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a live photo\'s long press plays instead of selecting', (
    tester,
  ) async {
    await _pumpViewer(
      tester,
      width: 411,
      textScale: 1.0,
      items: [_item(0), _item(1, live: true), _item(2)],
    );

    await _swipeTo(tester, 1, 411);
    await tester.longPress(find.byKey(_pageKey(1)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('badge_redownload')), findsNothing,
        reason: 'the live photo stays unselected');

    await tester.tap(find.byKey(const Key('browser_select_toggle')));
    await tester.pumpAndSettle();
    expect(_badgeCount(tester, 'badge_redownload'), 1,
        reason: 'the circle still selects the live photo');

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('全选 and 取消选择 are next to the circle', (tester) async {
    await _pumpViewer(tester, width: 411, textScale: 1.0, mode: _Mode.local);
    await _selectPage(tester, 0, 411);

    await tester.tap(find.byKey(const Key('select_all')));
    await tester.pumpAndSettle();
    expect(_badgeCount(tester, 'badge_redownload'), 3);

    await tester.tap(find.byKey(const Key('clear_selection')));
    await tester.pumpAndSettle();
    expect(_badgeCount(tester, 'badge_redownload'), 0);
    expect(find.byKey(const Key('select_all')), findsNothing,
        reason: 'the selection tools leave with the selection');

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
