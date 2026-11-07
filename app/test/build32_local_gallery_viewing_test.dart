import 'dart:async';
import 'dart:ui' as ui;

import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/widgets/decoded_image_keeper.dart';
import 'package:easysave/widgets/gallery_browser.dart';
import 'package:easysave/widgets/verified_asset_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';

/// Counts decodes per asset and size; [gate] holds a decode open.
class _CountingProvider extends ImageProvider<_CountingProvider> {
  _CountingProvider(this.id, this.original, this.loads, [this.gate]);
  final String id;
  final bool original;
  final Map<String, int> loads;
  final Completer<void>? gate;

  @override
  Future<_CountingProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(_CountingProvider key, ImageDecoderCallback decode) {
    loads['$id:${original ? 'original' : 'thumb'}'] =
        (loads['$id:${original ? 'original' : 'thumb'}'] ?? 0) + 1;
    return OneFrameImageStreamCompleter(() async {
      await gate?.future;
      return ImageInfo(image: _image!.clone());
    }());
  }

  @override
  bool operator ==(Object other) =>
      other is _CountingProvider && other.id == id && other.original == original;

  @override
  int get hashCode => Object.hash(id, original);
}

ui.Image? _image;

Future<void> _prepareImage(WidgetTester tester) async {
  _image ??= await tester.runAsync(() => createTestImage(width: 8, height: 8));
}

AssetEntity _asset(String id) => AssetEntity(
  id: id,
  typeInt: AssetType.image.index,
  width: 1290,
  height: 1608,
  title: '${id}_1.jpg',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final loads = <String, int>{};

  setUp(() {
    loads.clear();
    VerifiedAssetImage.resetKnownPresentForTesting();
    VerifiedAssetImage.existenceForTesting = (_) async => true;
    VerifiedAssetImage.providerForTesting =
        (asset, original, _) => _CountingProvider(asset.id, original, loads);
    GalleryLocatorService.instance.presenceProbeForTesting = (_) async => true;
    // Originals larger than the cache budget: only live images survive.
    PaintingBinding.instance.imageCache
      ..clear()
      ..maximumSize = 0;
  });

  tearDown(() {
    VerifiedAssetImage.existenceForTesting = null;
    VerifiedAssetImage.providerForTesting = null;
    GalleryLocatorService.instance.resetForTesting();
    PaintingBinding.instance.imageCache
      ..clear()
      ..maximumSize = 1000;
  });

  testWidgets('a local original decodes without a thumbnail or a loading indicator',
      (tester) async {
    await _prepareImage(tester);
    final gate = Completer<void>();
    VerifiedAssetImage.providerForTesting =
        (asset, original, _) => _CountingProvider(asset.id, original, loads, gate);
    await tester.pumpWidget(MaterialApp(
      home: VerifiedAssetImage(_asset('a'), fallback: const Text('fallback'),
          isOriginal: true, fit: BoxFit.contain),
    ));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(loads['a:thumb'], isNull, reason: 'no enlarged thumbnail placeholder');
    expect(loads['a:original'], 1);

    await tester.runAsync(() async {
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    final raw = tester.widget<RawImage>(find.byType(RawImage));
    expect(raw.image, isNotNull);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('swiping back to a seen local image does not decode it again',
      (tester) async {
    await _prepareImage(tester);
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    const photos = MethodChannel('com.fluttercandies/photo_manager');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(photos, (_) async => null);
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(photos, null));

    final items = [
      for (final id in ['p1', 'p2', 'p3', 'p4'])
        GalleryBrowserItem(index: int.parse(id.substring(1)) - 1, type: 'image',
            url: '', asset: _asset(id), filename: '${id}_1.jpg'),
    ];
    await tester.pumpWidget(MaterialApp(
      home: GalleryBrowserPage(items: items, authorName: 'a', title: 't',
          platform: 'xhs', postUrl: 'https://www.xiaohongshu.com/explore/p'),
    ));
    Future<void> settle() async {
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await settle();
    expect(loads['p1:original'], 1);
    expect(loads['p2:original'], 1, reason: 'the next page is decoded ahead');
    expect(find.byType(CircularProgressIndicator), findsNothing);

    for (var page = 0; page < 2; page++) {
      await tester.drag(find.byType(PageView), const Offset(-900, 0));
      await settle();
    }
    expect(loads['p3:original'], 1);
    for (var page = 0; page < 2; page++) {
      await tester.drag(find.byType(PageView), const Offset(900, 0));
      await settle();
    }
    // Back on the first page: still one decode each.
    expect(loads['p1:original'], 1);
    expect(loads['p2:original'], 1);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('the keeper holds at most its capacity, oldest released first', () {
    final keeper = DecodedImageKeeper(capacity: 2);
    final a = _CountingProvider('a', true, loads);
    final b = _CountingProvider('b', true, loads);
    final c = _CountingProvider('c', true, loads);
    keeper
      ..keep(a, ImageConfiguration.empty)
      ..keep(b, ImageConfiguration.empty)
      ..keep(a, ImageConfiguration.empty)
      ..keep(c, ImageConfiguration.empty);
    expect(keeper.length, 2);
    expect(keeper.holds(a), isTrue);
    expect(keeper.holds(b), isFalse);
    expect(keeper.holds(c), isTrue);
    keeper.dispose();
    expect(keeper.length, 0);
  });
}
