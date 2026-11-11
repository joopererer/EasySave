import 'dart:io';
import 'package:easysave/core/models.dart';
import 'package:easysave/services/shared_preview_cache.dart';
import 'package:easysave/widgets/shared.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'rendered CoverImage uses declared thumbnail and full image independently',
    (tester) async {
      final item =
          MediaItem(
              type: 'image',
              url: 'https://sns-img-bd.xhscdn.com/synthetic',
              thumbnailUrl: 'https://sns-img-qc.xhscdn.com/synthetic!small',
            )
            ..cachePostId = 'variant-widget'
            ..cacheItemIndex = 0;
      final keys = <String>[];
      final path = File('test/fixtures/build24/portrait.png').absolute.path;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(sharedPreviewChannel, (call) async {
        if (call.method == 'thumbnailRead') {
          keys.add((call.arguments as Map)['key'] as String);
          return path;
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(sharedPreviewChannel, null),
      );
      Future<CdnImage> render(bool full) async {
        await tester.pumpWidget(
          MaterialApp(
            home: SizedBox(
              width: 120,
              height: 180,
              child: CoverImage(
                item: item,
                platform: 'xhs',
                fullResolution: full,
              ),
            ),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
        return tester.widget<Image>(find.byType(Image)).image as CdnImage;
      }

      final thumb = await render(false);
      expect(thumb.cacheWidth, isNotNull);
      expect(thumb.cacheIdentity, 'xhs:variant-widget:0:thumb');
      final full = await render(true);
      expect(full.cacheWidth, isNull);
      expect(full.cacheIdentity, 'xhs:variant-widget:0:image');
      expect(
        keys,
        containsAll([
          opaquePreviewKey(thumb.cacheIdentity),
          opaquePreviewKey(full.cacheIdentity),
        ]),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
