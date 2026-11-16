// Copyright 2026 EasySave. All rights reserved.
// v1.11 batch 3: a live photo's long press is the animation, in the viewer.
//
// Build 55 device report: from the parse preview (remote mode) the fullscreen
// viewer turned a live photo's long press into a selection toggle, while the
// local history viewer played the clip. The transparent selection layer added
// in build 54 was opaque and sat on top of the picture, so the press never
// reached the live photo's own gesture and arrived as a tap instead.
//
// The rule, in both viewers:
//   * live photo long press  → play the motion clip, never a selection;
//   * selection              → the circle in the top bar, or a tap while
//                              multi-select is active;
//   * ordinary still         → build 54 behaviour (long press toggles the
//                              selection; tap selects while multi-select).

import 'dart:convert';
import 'dart:typed_data';

import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/widgets/gallery_browser.dart';
import 'package:easysave/widgets/verified_asset_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';

const String _postUrl = 'https://xhslink.cn/o/pSk2BZw53J';
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
);

class _LocalAsset extends AssetEntity {
  _LocalAsset({required super.id})
    : super(
        typeInt: AssetType.image.index,
        width: 1080,
        height: 1440,
        title: 'still.jpg',
      );
}

GalleryBrowserItem _live({AssetEntity? asset}) => GalleryBrowserItem(
  index: 0,
  // The motion clip URL stays inside the site's media hosts; in a widget test
  // the player itself is unavailable, which is why the seam counts the starts.
  videoUrl: 'https://sns-video-bd.xhscdn.com/live.mp4',
  type: 'live',
  url: 'https://sns-img.xhscdn.com/live-still.jpg',
  asset: asset,
);

GalleryBrowserItem _still({AssetEntity? asset}) => GalleryBrowserItem(
  index: 1,
  type: 'image',
  url: 'https://sns-img.xhscdn.com/still.jpg',
  asset: asset,
);

Future<void> _pump(
  WidgetTester tester,
  List<GalleryBrowserItem> items, {
  required Set<int> selected,
  ValueChanged<Set<int>>? onSelectionChanged,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: GalleryBrowserPage(
        items: items,
        initialIndex: 0,
        authorName: 'a',
        title: 't',
        platform: 'xhs',
        postUrl: _postUrl,
        // Anything selected puts the viewer in multi-select mode, which is the
        // state the remote preview arrived in.
        selectedIndices: selected,
        onSelectionChanged: onSelectionChanged,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    liveMotionStartsForTesting = 0;
    GalleryLocatorService.instance
      ..resetForTesting()
      ..presenceProbeForTesting = (_) async => true;
    VerifiedAssetImage.existenceForTesting = (_) async => true;
    VerifiedAssetImage.providerForTesting = (_, _, _) => MemoryImage(_png);
  });

  tearDown(() {
    VerifiedAssetImage.providerForTesting = null;
    VerifiedAssetImage.existenceForTesting = null;
    GalleryLocatorService.instance.resetForTesting();
    liveMotionStartsForTesting = 0;
  });

  testWidgets('remote viewer: a live photo long press plays, never selects', (
    tester,
  ) async {
    final selections = <Set<int>>[];
    await _pump(
      tester,
      [_live(), _still()],
      selected: {1},
      onSelectionChanged: selections.add,
    );

    await tester.longPress(find.byType(PageView));
    await tester.pump();

    expect(liveMotionStartsForTesting, 1, reason: 'the motion clip started');
    expect(
      selections.where((set) => set.contains(0)),
      isEmpty,
      reason: 'the live photo was not selected by the long press',
    );
  });

  testWidgets('local viewer: a live photo long press plays, never selects', (
    tester,
  ) async {
    final selections = <Set<int>>[];
    await _pump(
      tester,
      [_live(asset: _LocalAsset(id: 'live-0')), _still()],
      selected: {1},
      onSelectionChanged: selections.add,
    );

    await tester.longPress(find.byType(PageView));
    await tester.pump();

    expect(liveMotionStartsForTesting, 1);
    expect(selections.where((set) => set.contains(0)), isEmpty);
  });

  testWidgets('multi-select still selects a live photo on a tap', (
    tester,
  ) async {
    final selections = <Set<int>>[];
    await _pump(
      tester,
      [_live(), _still()],
      selected: {1},
      onSelectionChanged: selections.add,
    );

    await tester.tap(find.byType(PageView));
    await tester.pump();

    expect(
      selections.last,
      contains(0),
      reason: 'a tap is the way to select while multi-select is active',
    );
    expect(liveMotionStartsForTesting, 0);
  });

  testWidgets('an ordinary still keeps its build 54 long press', (
    tester,
  ) async {
    final selections = <Set<int>>[];
    // The still is the page in view here.
    await tester.pumpWidget(
      MaterialApp(
        home: GalleryBrowserPage(
          items: [_still(), _live()],
          initialIndex: 0,
          authorName: 'a',
          title: 't',
          platform: 'xhs',
          postUrl: _postUrl,
          selectedIndices: {4},
          onSelectionChanged: selections.add,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.longPress(find.byType(PageView));
    await tester.pump();

    expect(
      selections.where((set) => set.contains(1)),
      isNotEmpty,
      reason: 'a still still selects on a long press (build 54)',
    );
    expect(liveMotionStartsForTesting, 0);
  });
}
