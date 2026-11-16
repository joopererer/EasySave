// Copyright 2026 EasySave. All rights reserved.
// v1.11 batch 3: a still shows a soft frame first and sharpens in place.
//
// The placeholder (a thumbnail, usually already decoded) and the full-resolution
// image are given one display frame — the final image's aspect ratio — so
// nothing jumps and the picture is never shown small and then enlarged. The
// sharp frame fades in over the placeholder instead of replacing it, and if it
// never arrives the placeholder stays with the retry hint on top.

import 'dart:async';

import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/local_thumbnail_tiers.dart';
import 'package:easysave/widgets/gallery_browser.dart';
import 'package:easysave/widgets/staged_photo.dart';
import 'package:easysave/widgets/verified_asset_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _postUrl = 'https://www.xiaohongshu.com/explore/2118566677374022101';

AssetEntity _asset(String id, {int width = 1080, int height = 1440}) =>
    AssetEntity(
      id: id,
      typeInt: AssetType.image.index,
      width: width,
      height: height,
      title: '$id.jpg',
    );

class _BrokenProvider extends ImageProvider<_BrokenProvider> {
  const _BrokenProvider();

  @override
  Future<_BrokenProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_BrokenProvider>(this);

  @override
  ImageStreamCompleter loadImage(
    _BrokenProvider key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(
    Future<ImageInfo>.error(StateError('decode failed')),
  );
}

/// A provider that never produces a frame (the full file is still decoding).
class _NeverLoadingProvider extends ImageProvider<_NeverLoadingProvider> {
  const _NeverLoadingProvider();

  @override
  Future<_NeverLoadingProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_NeverLoadingProvider>(this);

  @override
  ImageStreamCompleter loadImage(
    _NeverLoadingProvider key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(Completer<ImageInfo>().future);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    HistoryDb.resetInstanceForTesting();
    VerifiedAssetImage.resetKnownPresentForTesting();
    final locator = GalleryLocatorService.instance..resetForTesting();
    locator.presenceProbeForTesting = (_) async => true;
  });

  tearDown(() {
    VerifiedAssetImage.providerForTesting = null;
    VerifiedAssetImage.existenceForTesting = null;
    GalleryLocatorService.instance.resetForTesting();
  });

  testWidgets('placeholder and full image share one box of the final aspect', (
    tester,
  ) async {
    late StagedPhotoSignals signals;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 300, maxHeight: 300),
              child: StagedPhoto(
                aspectRatio: 3 / 4,
                placeholder: const KeyedSubtree(
                  key: ValueKey('staged_placeholder'),
                  child: ColoredBox(color: Colors.grey),
                ),
                buildFull: (s) {
                  signals = s;
                  return const KeyedSubtree(
                    key: ValueKey('staged_full'),
                    child: ColoredBox(color: Colors.blue),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );

    final placeholder = tester.getRect(
      find.byKey(const ValueKey('staged_placeholder')),
    );
    final full = tester.getRect(find.byKey(const ValueKey('staged_full')));
    expect(
      full,
      placeholder,
      reason: 'the sharp frame lands exactly on the soft one',
    );
    expect(
      placeholder.width / placeholder.height,
      moreOrLessEquals(3 / 4, epsilon: 0.01),
    );
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      0,
      reason: 'the full layer is invisible while the placeholder shows',
    );

    signals.onFrame();
    await tester.pumpAndSettle();
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      1,
    );
    expect(
      kStagedPhotoCrossfade.inMilliseconds,
      inInclusiveRange(150, 200),
      reason: 'the fade stays in the 150–200 ms the design asks for',
    );
  });

  testWidgets('the cross-fade replaces the placeholder without moving it', (
    tester,
  ) async {
    late StagedPhotoSignals signals;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 200, maxHeight: 200),
              child: StagedPhoto(
                aspectRatio: 1,
                placeholder: const KeyedSubtree(
                  key: ValueKey('staged_placeholder'),
                  child: ColoredBox(color: Colors.grey),
                ),
                buildFull: (s) {
                  signals = s;
                  return const SizedBox.expand(key: ValueKey('staged_full'));
                },
              ),
            ),
          ),
        ),
      ),
    );
    final before = tester.getRect(
      find.byKey(const ValueKey('staged_placeholder')),
    );
    signals.onFrame();
    await tester.pump(const Duration(milliseconds: 90));
    final middle = tester.getRect(
      find.byKey(const ValueKey('staged_placeholder')),
    );
    expect(middle, before, reason: 'the frame does not move during the fade');
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byKey(const ValueKey('staged_placeholder'))),
      before,
    );
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      1,
    );
  });

  testWidgets('a local still shows its thumbnail first, then the sharp frame', (
    tester,
  ) async {
    final askedSizes = <ThumbnailSize>[];
    final png = Uint8List.fromList(_onePixelPng);
    VerifiedAssetImage.existenceForTesting = (_) async => true;
    VerifiedAssetImage.providerForTesting = (asset, isOriginal, size) {
      askedSizes.add(size);
      return MemoryImage(png);
    };

    await tester.pumpWidget(
      MaterialApp(
        home: GalleryBrowserPage(
          items: [
            GalleryBrowserItem(
              index: 3,
              type: 'image',
              url: '',
              asset: _asset('local-3'),
              status: FileStatus.found,
            ),
          ],
          authorName: 'a',
          title: 't',
          platform: 'xhs',
          postUrl: _postUrl,
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
    await tester.pumpAndSettle();

    expect(find.byType(StagedPhoto), findsOneWidget);
    expect(
      askedSizes,
      contains(LocalThumbnailTiers.medium),
      reason: 'the placeholder is the medium thumbnail, never the original',
    );
    final aspect = tester
        .widget<AspectRatio>(
          find.descendant(
            of: find.byType(StagedPhoto),
            matching: find.byType(AspectRatio),
          ),
        )
        .aspectRatio;
    expect(
      aspect,
      moreOrLessEquals(1080 / 1440, epsilon: 0.001),
      reason: 'the display frame is the final image, not the square thumbnail',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a full image that fails keeps the placeholder and shows the '
      'retry hint', (tester) async {
    VerifiedAssetImage.existenceForTesting = (_) async => true;
    VerifiedAssetImage.providerForTesting = (asset, isOriginal, size) =>
        isOriginal ? const _BrokenProvider() : MemoryImage(
          Uint8List.fromList(_onePixelPng),
        );

    await tester.pumpWidget(
      MaterialApp(
        home: GalleryBrowserPage(
          items: [
            GalleryBrowserItem(
              index: 0,
              type: 'image',
              url: 'https://www.example.com/a.jpg',
              asset: _asset('local-0'),
              status: FileStatus.found,
            ),
          ],
          authorName: 'a',
          title: 't',
          platform: 'xhs',
          postUrl: _postUrl,
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    await tester.pumpAndSettle();

    expect(
      find.byWidgetPredicate(
        (w) =>
            w is Text &&
            (w.data == '加载失败，点击重试' || w.data == '该资源地址不在允许范围内'),
      ),
      findsWidgets,
      reason: 'the retry affordance of the failed full image is on screen',
    );
    // The placeholder layer of the staged still is still there, visible under
    // the retry hint: the fade was revealed by the failure, never hidden.
    expect(find.byType(StagedPhoto), findsOneWidget);
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity).first).opacity,
      1,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a GIF is not staged: it animates from the first frame', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: GalleryBrowserPage(
          items: [
            GalleryBrowserItem(
              index: 0,
              type: 'image',
              url: 'https://www.example.com/a.gif',
              isGif: true,
            ),
          ],
          authorName: 'a',
          title: 't',
          platform: 'xhs',
          postUrl: _postUrl,
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(StagedPhoto), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets("turning the page shows the next still's placeholder at once", (
    tester,
  ) async {
    VerifiedAssetImage.existenceForTesting = (_) async => true;
    // The full-resolution file never decodes; only the thumbnail does.
    VerifiedAssetImage.providerForTesting = (asset, isOriginal, size) =>
        isOriginal
        ? const _NeverLoadingProvider()
        : MemoryImage(Uint8List.fromList(_onePixelPng));

    await tester.pumpWidget(
      MaterialApp(
        home: GalleryBrowserPage(
          items: [
            for (var i = 0; i < 2; i++)
              GalleryBrowserItem(
                index: i,
                type: 'image',
                url: '',
                asset: _asset('local-$i'),
                status: FileStatus.found,
              ),
          ],
          authorName: 'a',
          title: 't',
          platform: 'xhs',
          postUrl: _postUrl,
        ),
      ),
    );
    await tester.pump();

    await tester.drag(find.byType(PageView), const Offset(-400, 0));
    await tester.pump();

    final staged = tester.widgetList<StagedPhoto>(find.byType(StagedPhoto));
    expect(staged, isNotEmpty, reason: 'the new page is a staged still');
    expect(
      tester
          .widgetList<AnimatedOpacity>(find.byType(AnimatedOpacity))
          .every((w) => w.opacity == 0),
      isTrue,
      reason: 'while the sharp frame decodes the placeholder is what shows',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

const List<int> _onePixelPng = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
];
