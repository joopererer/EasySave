// Copyright 2026 EasySave. All rights reserved.
// v1.11 build 57: a live photo's motion clip is prepared while the page rests.
//
// Device report: in the remote preview a long press on a live photo waited for
// the whole motion clip to download before anything played, with nothing on
// screen to explain the wait. The clip is now prepared after the page has been
// in view for [kLiveMotionPreloadDelay]; a press that arrives earlier shows a
// spinner in the LIVE badge and starts playback the moment the clip is ready,
// still while the finger is down.
//
// Rules under test:
//   * preloaded      → the press plays at once, no spinner;
//   * not preloaded  → spinner, then playback while still holding;
//   * released early → no playback at all (the prepared clip is kept);
//   * leaving the page → the prepared clip is released, and only the page in
//     view ever prepares one.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/widgets/gallery_browser.dart';
import 'package:easysave/widgets/verified_asset_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const String _postUrl = 'https://xhslink.cn/o/pSk2BZw53J';
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
);

/// A motion clip that needs no player plugin.
class _FakeLiveMotion implements LiveMotion {
  _FakeLiveMotion(this.index);

  final int index;
  int playCalls = 0;
  int disposeCalls = 0;

  @override
  bool get ready => true;

  @override
  double get aspectRatio => 0.75;

  @override
  Widget buildView() => SizedBox.expand(key: Key('fake-live-view-$index'));

  @override
  Future<void> play() async {
    playCalls++;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
  }
}

GalleryBrowserItem _live() => GalleryBrowserItem(
  index: 0,
  type: 'live',
  url: 'https://sns-img.xhscdn.com/live-still.jpg',
  videoUrl: 'https://sns-video-bd.xhscdn.com/live.mp4',
);

GalleryBrowserItem _still() => GalleryBrowserItem(
  index: 1,
  type: 'image',
  url: 'https://sns-img.xhscdn.com/still.jpg',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final loads = <_FakeLiveMotion>[];
  Completer<LiveMotion>? gate;

  setUp(() {
    loads.clear();
    gate = null;
    liveMotionStartsForTesting = 0;
    GalleryLocatorService.instance
      ..resetForTesting()
      ..presenceProbeForTesting = (_) async => true;
    VerifiedAssetImage.existenceForTesting = (_) async => true;
    VerifiedAssetImage.providerForTesting = (_, _, _) => MemoryImage(_png);
    liveMotionLoaderForTesting = (item, platform) {
      final clip = _FakeLiveMotion(loads.length);
      loads.add(clip);
      final pending = gate;
      if (pending == null) return Future<LiveMotion>.value(clip);
      return pending.future;
    };
  });

  tearDown(() {
    liveMotionLoaderForTesting = null;
    VerifiedAssetImage.providerForTesting = null;
    VerifiedAssetImage.existenceForTesting = null;
    GalleryLocatorService.instance.resetForTesting();
    liveMotionStartsForTesting = 0;
    loads.clear();
    gate = null;
  });

  Future<void> pumpViewer(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: GalleryBrowserPage(
          items: [_live(), _still()],
          initialIndex: 0,
          authorName: 'a',
          title: 't',
          platform: 'xhs',
          postUrl: _postUrl,
          selectedIndices: const <int>{},
          onSelectionChanged: (_) {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('a resting live photo prepares its clip, so the press plays at '
      'once', (tester) async {
    await pumpViewer(tester);
    expect(loads, isEmpty, reason: 'nothing is fetched before the page rests');

    await tester.pump(kLiveMotionPreloadDelay + const Duration(milliseconds: 50));
    expect(loads, hasLength(1), reason: 'the clip was prepared while resting');
    expect(loads.single.disposeCalls, 0);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(PageView)),
    );
    await tester.pump(const Duration(milliseconds: 600));

    expect(loads.single.playCalls, 1, reason: 'the prepared clip plays at once');
    expect(
      find.byKey(kLiveMotionLoadingKey),
      findsNothing,
      reason: 'a prepared clip needs no spinner',
    );
    expect(find.byKey(const Key('fake-live-view-0')), findsOneWidget);

    await gesture.up();
    await tester.pump();
    expect(loads.single.disposeCalls, 1, reason: 'release stops the clip');
  });

  testWidgets('a press before the clip is ready shows the LIVE spinner and '
      'then plays while still holding', (tester) async {
    gate = Completer<LiveMotion>();
    await pumpViewer(tester);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(PageView)),
    );
    await tester.pump(const Duration(milliseconds: 600));

    expect(loads, hasLength(1));
    expect(
      find.byKey(kLiveMotionLoadingKey),
      findsOneWidget,
      reason: 'the wait is explained at the LIVE badge',
    );
    expect(loads.single.playCalls, 0);

    gate!.complete(loads.single);
    await tester.pump();
    await tester.pump();

    expect(
      loads.single.playCalls,
      1,
      reason: 'playback starts as soon as the clip is ready, still holding',
    );
    expect(find.byKey(kLiveMotionLoadingKey), findsNothing);

    await gesture.up();
    await tester.pump();
    expect(loads.single.disposeCalls, 1);
  });

  testWidgets('releasing before the clip is ready starts no playback and keeps '
      'the clip for the next press', (tester) async {
    gate = Completer<LiveMotion>();
    await pumpViewer(tester);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(PageView)),
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byKey(kLiveMotionLoadingKey), findsOneWidget);

    await gesture.up();
    await tester.pump();
    gate!.complete(loads.single);
    await tester.pump();
    await tester.pump();

    expect(loads.single.playCalls, 0, reason: 'nothing plays after the release');
    expect(loads.single.disposeCalls, 0, reason: 'the clip stays ready');

    // The next press uses it immediately.
    final again = await tester.startGesture(
      tester.getCenter(find.byType(PageView)),
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(loads.single.playCalls, 1);
    expect(loads, hasLength(1), reason: 'no second fetch');
    await again.up();
    await tester.pump();
  });

  testWidgets('leaving the page releases the prepared clip', (tester) async {
    await pumpViewer(tester);
    await tester.pump(kLiveMotionPreloadDelay + const Duration(milliseconds: 50));
    expect(loads, hasLength(1));
    expect(loads.single.disposeCalls, 0);

    await tester.fling(find.byType(PageView), const Offset(-500, 0), 1000);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      loads.single.disposeCalls,
      1,
      reason: 'only the page in view keeps a clip (leaving cancels it)',
    );
    expect(loads, hasLength(1), reason: 'the next page is a still: nothing else '
        'is prepared');
  });
}
