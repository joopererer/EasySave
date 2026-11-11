import 'dart:async';
import 'dart:ui' as ui;
import 'package:easysave/widgets/verified_asset_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';

void main() {
  final asset = AssetEntity(id: 'saved-thumb', typeInt: 1, width: 2, height: 2);
  final provider = AssetEntityImageProvider(
    asset,
    isOriginal: false,
    thumbnailSize: const ThumbnailSize.square(400),
  );
  Future<void> cacheThumb(WidgetTester tester) async {
    final recorder = ui.PictureRecorder();
    Canvas(
      recorder,
    ).drawRect(const Rect.fromLTWH(0, 0, 2, 2), Paint()..color = Colors.pink);
    final picture = recorder.endRecording();
    final image = await tester.runAsync(() => picture.toImage(2, 2));
    picture.dispose();
    PaintingBinding.instance.imageCache.putIfAbsent(
      provider,
      () => OneFrameImageStreamCompleter(
        SynchronousFuture(ImageInfo(image: image!)),
      ),
    );
    await tester.pump();
    expect(
      PaintingBinding.instance.imageCache.statusForKey(provider).keepAlive,
      isTrue,
    );
  }

  tearDown(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });
  testWidgets(
    'layout remount reuses decoded thumbnail without fallback while freshly checking existence',
    (tester) async {
      await cacheThumb(tester);
      var checks = 0;
      final pending = <Completer<bool>>[];
      Future<bool> verify(String _) {
        checks++;
        final c = Completer<bool>();
        pending.add(c);
        return c.future;
      }

      Widget thumb() => VerifiedAssetImage(
        asset,
        verifyExistence: verify,
        fallback: const Text('network fallback'),
      );
      await tester.pumpWidget(
        MaterialApp(home: SizedBox(width: 76, height: 76, child: thumb())),
      );
      expect(find.text('network fallback'), findsNothing);
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
      pending.first.complete(true);
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
        MaterialApp(home: AspectRatio(aspectRatio: 0.75, child: thumb())),
      );
      expect(checks, 2);
      expect(find.text('network fallback'), findsNothing);
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
      pending.last.complete(false);
      await tester.pumpAndSettle();
      expect(find.text('network fallback'), findsOneWidget);
      expect(
        PaintingBinding.instance.imageCache.containsKey(provider),
        isFalse,
      );
    },
  );
  testWidgets(
    'cold verification does not build remote fallback before the result',
    (tester) async {
      final pending = Completer<bool>();
      var remoteBuilds = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: VerifiedAssetImage(
            asset,
            verifyExistence: (_) => pending.future,
            fallback: Builder(
              builder: (_) {
                remoteBuilds++;
                return const Text('fallback');
              },
            ),
          ),
        ),
      );
      expect(remoteBuilds, 0);
      pending.complete(false);
      await tester.pumpAndSettle();
      expect(remoteBuilds, 1);
      expect(find.text('fallback'), findsOneWidget);
    },
  );
  testWidgets(
    'changing asset ID does not retain another post image through gapless playback',
    (tester) async {
      await cacheThumb(tester);
      final a = Completer<bool>(), b = Completer<bool>();
      await tester.pumpWidget(
        MaterialApp(
          home: VerifiedAssetImage(
            asset,
            verifyExistence: (_) => a.future,
            fallback: const Text('fallback'),
          ),
        ),
      );
      expect(find.byType(RawImage), findsOneWidget);
      final other = AssetEntity(
        id: 'other-post',
        typeInt: 1,
        width: 2,
        height: 2,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: VerifiedAssetImage(
            other,
            verifyExistence: (_) => b.future,
            fallback: const Text('fallback'),
          ),
        ),
      );
      expect(find.byType(RawImage), findsNothing);
      a.complete(true);
      b.complete(false);
      await tester.pumpAndSettle();
      expect(find.text('fallback'), findsOneWidget);
    },
  );
}
