// v1.10 build 34 / problem 2: the saved-media viewer decodes at the screen
// size instead of the original pixels (Xiaohongshu originals reach 5152x6864),
// puts the MediaStore system thumbnail underneath while the sharp tier
// decodes, loads the original only while zoomed past ~2x, and drops it again
// when zooming back out.

import 'dart:async';
import 'dart:ui' as ui;

import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/widgets/decoded_image_keeper.dart';
import 'package:easysave/widgets/gallery_browser.dart';
import 'package:easysave/widgets/progressive_asset_image.dart';
import 'package:easysave/widgets/verified_asset_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';

class _TierProvider extends ImageProvider<_TierProvider> {
  _TierProvider(this.id, this.tier, this.loads, {this.gate, this.image});
  final String id;
  final String tier;
  final Map<String, int> loads;
  final Completer<void>? gate;
  final ui.Image? image;

  String get label => '$id:$tier';

  @override
  Future<_TierProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _TierProvider key,
    ImageDecoderCallback decode,
  ) {
    loads[label] = (loads[label] ?? 0) + 1;
    return OneFrameImageStreamCompleter(() async {
      await gate?.future;
      return ImageInfo(image: image!.clone());
    }());
  }

  @override
  bool operator ==(Object other) =>
      other is _TierProvider && other.id == id && other.tier == tier;

  @override
  int get hashCode => Object.hash(id, tier);
}

/// The Xiaohongshu original size that made the viewer decode 141 MB bitmaps.
const _originalWidth = 5152;
const _originalHeight = 6864;

AssetEntity _asset(String id) => AssetEntity(
  id: id,
  typeInt: AssetType.image.index,
  width: _originalWidth,
  height: _originalHeight,
  title: '${id}_1.jpg',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final loads = <String, int>{};
  ui.Image? frame;

  setUp(() {
    loads.clear();
    VerifiedAssetImage.resetKnownPresentForTesting();
    VerifiedAssetImage.existenceForTesting = (_) async => true;
    GalleryLocatorService.instance.presenceProbeForTesting = (_) async => true;
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  });

  tearDown(() {
    VerifiedAssetImage.existenceForTesting = null;
    VerifiedAssetImage.providerForTesting = null;
    GalleryLocatorService.instance.resetForTesting();
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  });

  Future<ui.Image> prepared(WidgetTester tester) async =>
      frame ??= (await tester.runAsync(
        () => createTestImage(width: 8, height: 8),
      ))!;

  test('a 5152x6864 original is decoded at the screen pixels, keeping its '
      'aspect ratio and staying inside the screen', () {
    const screen = Size(1080, 2400);
    final target = decodeTargetFor(
      imageWidth: _originalWidth,
      imageHeight: _originalHeight,
      screenPixels: screen,
    );
    expect(target.width, lessThanOrEqualTo(screen.width));
    expect(target.height, lessThanOrEqualTo(screen.height));
    expect(target.width, lessThanOrEqualTo(_originalWidth));
    expect(target.height, lessThanOrEqualTo(_originalHeight));
    expect(
      target.width / target.height,
      closeTo(_originalWidth / _originalHeight, 0.01),
    );
    // 141 MB of pixels (5152 x 6864 x 4) must never be allocated for the
    // fullscreen view.
    final fullBytes = _originalWidth * _originalHeight * 4;
    final targetBytes = target.width * target.height * 4;
    expect(targetBytes, lessThan(fullBytes / 20));

    // A portrait screen and a landscape screen both stay inside the box.
    final landscape = decodeTargetFor(
      imageWidth: _originalWidth,
      imageHeight: _originalHeight,
      screenPixels: const Size(2400, 1080),
    );
    expect(landscape.width, lessThanOrEqualTo(2400));
    expect(landscape.height, lessThanOrEqualTo(1080));
    // Unknown dimensions fall back to the screen box.
    expect(
      decodeTargetFor(
        imageWidth: 0,
        imageHeight: 0,
        screenPixels: screen,
      ),
      screen,
    );
  });

  testWidgets(
    'the viewer asks for a screen-size decode plus the system thumbnail '
    'underlay, and keeps the original only as the zoom tier',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 400,
            height: 800,
            child: VerifiedAssetImage(
              _asset('p1'),
              fallback: const Text('fallback'),
              isOriginal: true,
              fit: BoxFit.contain,
            ),
          ),
        ),
      );
      await tester.pump();
      final progressive = tester.widget<ProgressiveAssetImage>(
        find.byType(ProgressiveAssetImage),
      );
      final sharp = progressive.sharp;
      expect(sharp, isA<ResizeImage>(),
          reason: 'the sharp tier is a resized decode, not the original');
      final resized = sharp as ResizeImage;
      const screen = Size(1080, 2400);
      final expected = decodeTargetFor(
        imageWidth: _originalWidth,
        imageHeight: _originalHeight,
        screenPixels: screen,
      );
      expect(resized.width, expected.width.round());
      expect(resized.height, expected.height.round());
      expect(resized.width! * resized.height!,
          lessThan(_originalWidth * _originalHeight ~/ 20));
      expect(resized.policy, ResizeImagePolicy.fit);
      expect(
        (resized.imageProvider as AssetEntityImageProvider).isOriginal,
        isTrue,
      );

      final underlay = progressive.underlay;
      expect(underlay, isNotNull, reason: 'MediaStore thumbnail underlay');
      expect((underlay! as AssetEntityImageProvider).isOriginal, isFalse);
      expect(
        (underlay as AssetEntityImageProvider).thumbnailSize,
        ThumbnailSize(expected.width.round(), expected.height.round()),
      );

      // The original is only reachable through the zoom tier.
      expect(progressive.original, isNotNull);
      expect(
        (progressive.original! as AssetEntityImageProvider).isOriginal,
        isTrue,
      );
      expect(find.byKey(const ValueKey('original')), findsNothing,
          reason: 'no original is decoded while not zoomed');

      // Let the (test-environment) decodes and their timers drain, then drop
      // the tree so no timer outlives the test.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets(
    'the thumbnail tier paints while the sharp tier is still decoding, so a '
    'swipe shows pixels instead of a black gap and no loading spinner',
    (tester) async {
      final image = await prepared(tester);
      final gate = Completer<void>();
      VerifiedAssetImage.providerForTesting = (asset, original, _) =>
          _TierProvider(asset.id, original ? 'original' : 'thumb', loads,
              gate: original ? gate : null, image: image);

      await tester.pumpWidget(
        MaterialApp(
          home: GalleryBrowserPage(
            items: [
              GalleryBrowserItem(
                index: 0,
                type: 'image',
                url: '',
                asset: _asset('p2'),
                filename: 'p2_1.jpg',
              ),
            ],
            authorName: 'a',
            title: 't',
            platform: 'xhs',
            postUrl: 'https://www.xiaohongshu.com/explore/p',
          ),
        ),
      );
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(loads['p2:thumb'], 1, reason: 'the system thumbnail underlay');
      expect(loads['p2:original'], 1, reason: 'the sharp tier is decoding');
      expect(find.byType(ProgressiveAssetImage), findsWidgets,
          reason: 'the progressive cover is mounted');
      final underlay = tester.widget<RawImage>(
        find
            .descendant(
              of: find.byKey(const ValueKey('underlay')),
              matching: find.byType(RawImage),
            )
            .first,
      );
      expect(underlay.image, isNotNull,
          reason: 'the thumbnail paints before the sharp tier');
      final sharp = tester.widget<RawImage>(
        find
            .descendant(
              of: find.byKey(const ValueKey('sharp')),
              matching: find.byType(RawImage),
            )
            .first,
      );
      expect(sharp.image, isNull);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      await tester.runAsync(() async {
        gate.complete();
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pumpAndSettle();
      final sharpAfter = tester.widget<RawImage>(
        find
            .descendant(
              of: find.byKey(const ValueKey('sharp')),
              matching: find.byType(RawImage),
            )
            .first,
      );
      expect(sharpAfter.image, isNotNull);
    },
  );

  testWidgets(
    'pinching past 2x adds the original tier and zooming back out releases it',
    (tester) async {
      final image = await prepared(tester);
      VerifiedAssetImage.providerForTesting = (asset, original, _) =>
          _TierProvider(asset.id, original ? 'original' : 'thumb', loads,
              image: image);

      await tester.pumpWidget(
        MaterialApp(
          home: GalleryBrowserPage(
            items: [
              GalleryBrowserItem(
                index: 0,
                type: 'image',
                url: '',
                asset: _asset('p1'),
                filename: 'p1_1.jpg',
              ),
            ],
            authorName: 'a',
            title: 't',
            platform: 'xhs',
            postUrl: 'https://www.xiaohongshu.com/explore/p',
          ),
        ),
      );
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.byKey(const ValueKey('original')), findsNothing);

      final viewer = tester.widget<InteractiveViewer>(
        find.byType(InteractiveViewer).first,
      );
      final controller = viewer.transformationController!;
      final original = VerifiedAssetImage.providerFor(_asset('p1'),
          isOriginal: true);

      // Zoom past the threshold: the original tier is decoded on demand.
      controller.value = Matrix4.identity()..scaleByDouble(2.5, 2.5, 1.0, 1.0);
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('original')), findsOneWidget);
      expect(loads['p1:original'], greaterThanOrEqualTo(1));

      // Zoom back out: the tier is removed and dropped from the image cache.
      expect(PaintingBinding.instance.imageCache.containsKey(original), isTrue);
      controller.value = Matrix4.identity();
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('original')), findsNothing);
      expect(
        PaintingBinding.instance.imageCache.containsKey(original),
        isFalse,
        reason: 'the original leaves the cache when zoomed back out',
      );
    },
  );

  testWidgets('the decoded-image keeper honours a byte budget of decoded '
      'pixels', (tester) async {
    final image = await tester.runAsync(() => createTestImage(width: 100, height: 100));
    final keeper = DecodedImageKeeper(
      capacity: 8,
      // Two 100x100 images fit, the third pushes the oldest out.
      maxDecodedBytes: 2 * 100 * 100 * 4,
    );
    final providers = <String, _ImmediateProvider>{
      for (final id in ['a', 'b', 'c'])
        id: _ImmediateProvider(id, image!),
    };
    for (final provider in providers.values) {
      keeper.keep(provider, ImageConfiguration.empty);
    }
    expect(keeper.decodedBytes, 2 * 100 * 100 * 4);
    expect(keeper.length, 2);
    expect(keeper.holds(providers['a']!), isFalse,
        reason: 'the oldest decoded image is released first');
    expect(keeper.holds(providers['c']!), isTrue);
    keeper.dispose();
    expect(keeper.length, 0);
  });
}

/// Resolves with a ready frame, so the keeper's byte accounting is exercised.
class _ImmediateProvider extends ImageProvider<_ImmediateProvider> {
  _ImmediateProvider(this.id, this.image);
  final String id;
  final ui.Image image;

  @override
  Future<_ImmediateProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _ImmediateProvider key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(
    SynchronousFuture(ImageInfo(image: image.clone())),
  );

  @override
  bool operator ==(Object other) => other is _ImmediateProvider && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
