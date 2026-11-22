import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:easysave/core/dev_log.dart';
import 'package:easysave/widgets/verified_asset_image.dart';

class _FakeAssetEntity extends Fake implements AssetEntity {
  _FakeAssetEntity(this.id);
  @override
  final String id;
}

class _CompletableImageProvider extends ImageProvider<_CompletableImageProvider> {
  _CompletableImageProvider(this.completer, {this.onLoad});
  final Completer<ui.Image> completer;
  final VoidCallback? onLoad;

  @override
  Future<_CompletableImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<_CompletableImageProvider>(this);
  }

  @override
  ImageStreamCompleter loadImage(_CompletableImageProvider key, ImageDecoderCallback decode) {
    onLoad?.call();
    final streamCompleter = OneFrameImageStreamCompleter(
      completer.future.then((image) => ImageInfo(image: image)),
    );
    return streamCompleter;
  }

  @override
  bool operator ==(Object other) => identical(this, other) || other is _CompletableImageProvider && other.completer == completer;

  @override
  int get hashCode => completer.hashCode;
}

Future<ui.Image> _createTestImage() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(const Rect.fromLTWH(0, 0, 10, 10), Paint()..color = Colors.blue);
  final picture = recorder.endRecording();
  return picture.toImage(10, 10);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    DevLog.resetRecentForTesting();
    VerifiedAssetImage.existenceForTesting = (_) async => true;
    VerifiedAssetImage.lateRetryDelay = const Duration(milliseconds: 50);
  });

  tearDown(() {
    VerifiedAssetImage.existenceForTesting = null;
    VerifiedAssetImage.providerForTesting = null;
    VerifiedAssetImage.lateRetryDelay = const Duration(seconds: 20);
  });

  group('v1.12 build 75 Item B: thumbnail late arrival and single retry', () {
    testWidgets('B1: late frame arriving after timeout is adopted with late_ok and 180ms fade-in', (tester) async {
      final completer = Completer<ui.Image>();
      VerifiedAssetImage.providerForTesting = (asset, isOriginal, size) => _CompletableImageProvider(completer);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VerifiedAssetImage(
              _FakeAssetEntity('asset_late_1'),
              fallback: const Text('FALLBACK_TEXT'),
            ),
          ),
        ),
      );

      // Initially verifying existence
      await tester.pump(const Duration(milliseconds: 10));

      // Advance 5 seconds to trigger timeout
      await tester.pump(const Duration(seconds: 5));
      expect(find.text('FALLBACK_TEXT'), findsOneWidget);

      // Now complete the delayed native frame
      final testImage = await _createTestImage();
      completer.complete(testImage);

      // Next tick receives the frame and triggers late_ok
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final lines = DevLog.recentLines(50);
      expect(lines.any((l) => l.contains('ThumbLoad') && l.contains('event=late_ok')), isTrue);
      expect(find.byType(AnimatedSwitcher), findsOneWidget);
    });

    testWidgets('B2: unmounted widget does not trigger rebuild on late arrival', (tester) async {
      final completer = Completer<ui.Image>();
      VerifiedAssetImage.providerForTesting = (asset, isOriginal, size) => _CompletableImageProvider(completer);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VerifiedAssetImage(
              _FakeAssetEntity('asset_late_unmount'),
              fallback: const Text('FALLBACK_TEXT'),
            ),
          ),
        ),
      );

      await tester.pump(const Duration(seconds: 5));
      expect(find.text('FALLBACK_TEXT'), findsOneWidget);

      // Unmount the widget (simulating card leaving screen)
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SizedBox.shrink())),
      );

      // Complete late frame after unmounting
      final testImage = await _createTestImage();
      completer.complete(testImage);
      await tester.pump(const Duration(milliseconds: 100));

      // Verify no exception was thrown and no setState on unmounted
      expect(find.text('FALLBACK_TEXT'), findsNothing);
    });

    testWidgets('B3: 20s retry occurs only once when mounted', (tester) async {
      VerifiedAssetImage.lateRetryDelay = const Duration(milliseconds: 200);

      var loadCount = 0;
      final completers = [Completer<ui.Image>(), Completer<ui.Image>()];

      VerifiedAssetImage.providerForTesting = (asset, isOriginal, size) {
        return _CompletableImageProvider(
          completers[loadCount.clamp(0, completers.length - 1)],
          onLoad: () => loadCount++,
        );
      };

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VerifiedAssetImage(
              _FakeAssetEntity('asset_retry_test'),
              fallback: const Text('FALLBACK_RETRY'),
            ),
          ),
        ),
      );

      await tester.pump(const Duration(seconds: 5));
      expect(find.text('FALLBACK_RETRY'), findsOneWidget);
      expect(loadCount, 1);

      // Advance by 200ms (lateRetryDelay)
      await tester.pump(const Duration(milliseconds: 200));

      // Retry should have been initiated (loadCount becomes 2)
      expect(loadCount, 2);

      // Complete retry
      final testImage = await _createTestImage();
      completers[1].complete(testImage);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final lines = DevLog.recentLines(50);
      expect(lines.any((l) => l.contains('ThumbLoad') && l.contains('event=late_retry key=') && l.contains('result=ok')), isTrue);

      // Advance time much further; retry must NOT occur again (loadCount stays 2)
      await tester.pump(const Duration(milliseconds: 500));
      expect(loadCount, 2);
    });
  });
}

