// Copyright 2026 EasySave. All rights reserved.
// v1.11 batch 5: the bottom bar of the viewer never overflows.
//
// The bar keeps icons only (each with a tooltip and a semantics label), the
// missing-items button keeps its words, and the hint is dropped before the
// buttons are squeezed. This covers the three shapes the bar can take — local
// album with missing items, local album without them, and the remote preview —
// at the narrow, common and wide widths and at two text scales.

import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/widgets/gallery_browser.dart';
import 'package:easysave/widgets/verified_asset_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _postUrl = 'https://www.xiaohongshu.com/explore/2118566677374022101';

GalleryBrowserItem _item(int index, {bool missing = false}) =>
    GalleryBrowserItem(
      index: index,
      type: 'image',
      url: '',
      missing: missing,
      status: missing ? FileStatus.notFound : FileStatus.found,
    );

List<GalleryBrowserItem> _items({required bool missing}) => [
  for (var index = 0; index < 4; index++)
    _item(index, missing: missing && index == 1),
];

/// The three shapes of the viewer's bottom bar.
enum _Mode {
  /// Local album with one item the album confirmed as gone.
  localWithMissing,

  /// Local album, every item still on the device.
  local,

  /// The remote preview: no delete, no re-parse, a 保存 button closing it.
  remote,
}

Future<void> _pumpViewer(
  WidgetTester tester, {
  required double width,
  required double textScale,
  required _Mode mode,
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
          items: _items(missing: mode == _Mode.localWithMissing),
          originalTotal: 4,
          authorName: '作者名字',
          title: '一个足够长的标题用来占位',
          platform: 'xhs',
          postUrl: _postUrl,
          showSave: mode == _Mode.remote,
          onRedownloadItems: local ? (indices) async => null : null,
          onDeleteItem: local
              ? (item, {required bool deleteAlbumFiles}) async =>
                    const GalleryBrowserItemDeletion(ok: true)
              : null,
          onReparse: local ? () {} : null,
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    VerifiedAssetImage.resetKnownPresentForTesting();
    GalleryLocatorService.instance
      ..resetForTesting()
      ..presenceProbeForTesting = (_) async => true;
  });

  tearDown(() {
    GalleryLocatorService.instance.resetForTesting();
  });

  group('the bottom bar fits', () {
    for (final width in <double>[320, 360, 411]) {
      for (final scale in <double>[1.0, 1.3]) {
        for (final mode in _Mode.values) {
          testWidgets(
            '${width.toInt()} dp at $scale with ${mode.name}',
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

              final primary = find.byKey(
                const Key('browser_primary_action'),
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
                // Either on the bar or folded into the 「更多」 menu, the way to
                // re-download the missing items is always reachable.
                final onBar = find.byKey(const Key('redownload_missing'));
                final inMenu = find.byKey(const Key('browser_more'));
                expect(
                  onBar.evaluate().isNotEmpty || inMenu.evaluate().isNotEmpty,
                  isTrue,
                );
              }

              await tester.pumpWidget(const SizedBox.shrink());
            },
          );
        }
      }
    }
  });

  testWidgets('every action is an icon with a tooltip and a label', (
    tester,
  ) async {
    await _pumpViewer(
      tester,
      width: 411,
      textScale: 1.0,
      mode: _Mode.localWithMissing,
    );

    expect(find.byTooltip('删除这张'), findsOneWidget);
    expect(find.byTooltip('重新解析'), findsOneWidget);
    expect(find.byTooltip('打开原帖'), findsOneWidget);
    expect(find.byTooltip('分享'), findsOneWidget);
    expect(find.byTooltip('补下缺失的 1 张'), findsOneWidget);

    // The semantics label of each icon carries the same words as its tooltip.
    final handle = tester.ensureSemantics();
    expect(find.bySemanticsLabel('删除这张'), findsWidgets);
    expect(find.bySemanticsLabel('重新解析'), findsWidgets);
    expect(find.bySemanticsLabel('打开原帖'), findsWidgets);
    expect(find.bySemanticsLabel('分享'), findsWidgets);
    handle.dispose();

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the remote preview keeps its 保存 action', (tester) async {
    await _pumpViewer(
      tester,
      width: 320,
      textScale: 1.3,
      mode: _Mode.remote,
    );
    expect(find.byTooltip('保存'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a short bar drops the hint before the buttons', (tester) async {
    await _pumpViewer(tester, width: 411, textScale: 1.0, mode: _Mode.local);
    expect(find.byKey(const Key('browser_hint')), findsOneWidget);

    await _pumpViewer(
      tester,
      width: 320,
      textScale: 1.3,
      mode: _Mode.localWithMissing,
    );
    expect(
      find.byKey(const Key('browser_hint')),
      findsNothing,
      reason: 'the hint goes first: it may not squeeze the actions',
    );
    expect(find.byTooltip('分享'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
