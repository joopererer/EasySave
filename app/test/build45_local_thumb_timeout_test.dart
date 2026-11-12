import 'dart:async';

import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/widgets/verified_asset_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';

// v1.10.3: one local thumbnail that never decodes must not leave the card
// blank forever, and must not block anything else. Each widget owns its own
// deadline (no shared gate — the build 36 lesson), and a miss is logged as
// `[ThumbLoad] event=local_decode_failed`.

AssetEntity _asset(String id) => AssetEntity(
  id: id,
  typeInt: AssetType.image.index,
  width: 1536,
  height: 2560,
  title: '6af3c278000000001c031f21_$id.heic',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    VerifiedAssetImage.resetKnownPresentForTesting();
    GalleryLocatorService.instance.presenceProbeForTesting = (_) async => true;
  });

  tearDown(() {
    VerifiedAssetImage.existenceForTesting = null;
    VerifiedAssetImage.providerForTesting = null;
  });

  testWidgets('an unanswered local thumbnail falls back after its deadline',
      (tester) async {
    // Never answers: the HEIC the Android 12 decoder stalls on.
    final stuck = Completer<bool>();
    VerifiedAssetImage.existenceForTesting = (_) => stuck.future;
    VerifiedAssetImage.providerForTesting =
        (asset, original, _) => _NeverLoadingProvider(asset.id);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 100,
            height: 100,
            child: VerifiedAssetImage(
              _asset('1'),
              fallback: const ColoredBox(
                key: ValueKey('fallback'),
                color: Color(0xFF00FF00),
              ),
            ),
          ),
        ),
      ),
    );

    // Inside the deadline the area stays empty on purpose.
    expect(find.byKey(const ValueKey('fallback')), findsNothing);

    await tester.pump(kLocalThumbnailTimeout + const Duration(milliseconds: 1));
    await tester.pump();

    expect(find.byKey(const ValueKey('fallback')), findsOneWidget);
    await tester.pumpAndSettle(const Duration(milliseconds: 1));
  });

  testWidgets('a second item is unaffected by a stuck first item',
      (tester) async {
    final stuck = Completer<bool>();
    var calls = 0;
    VerifiedAssetImage.existenceForTesting = (id) {
      calls++;
      return id == 'stuck' ? stuck.future : Future.value(true);
    };
    VerifiedAssetImage.providerForTesting =
        (asset, original, _) => _NeverLoadingProvider(asset.id);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              SizedBox(
                width: 80,
                height: 80,
                child: VerifiedAssetImage(
                  _asset('stuck'),
                  fallback: const ColoredBox(color: Color(0xFF00FF00)),
                ),
              ),
              SizedBox(
                width: 80,
                height: 80,
                child: VerifiedAssetImage(
                  _asset('fine'),
                  fallback: const ColoredBox(color: Color(0xFF0000FF)),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    // Both existence checks were started: nothing is serialised behind the
    // stuck one.
    expect(calls, 2);
    await tester.pump();
    expect(find.byType(Image), findsOneWidget,
        reason: 'the healthy item draws its image straight away');
  });
}

/// An image provider that never produces a frame, like a decode that never
/// returns. It signals its own beginning so the widget starts loading.
class _NeverLoadingProvider extends ImageProvider<_NeverLoadingProvider> {
  _NeverLoadingProvider(this.id);
  final String id;

  @override
  Future<_NeverLoadingProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_NeverLoadingProvider>(this);

  @override
  ImageStreamCompleter loadImage(
    _NeverLoadingProvider key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(Completer<ImageInfo>().future);
}
