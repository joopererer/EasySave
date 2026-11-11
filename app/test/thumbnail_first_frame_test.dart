import 'dart:async';
import 'package:easysave/core/models.dart';
import 'package:easysave/pages/preview_page.dart';
import 'package:easysave/services/shared_preview_cache.dart';
import 'package:easysave/widgets/shared.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'real CoverImage decodes at logical width times DPR and originals opt in',
    (tester) async {
      final blocked = Completer<String?>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(sharedPreviewChannel, (call) async {
            if (call.method == 'thumbnailAcquire') return true;
            if (call.method == 'thumbnailRead') return blocked.future;
            return null;
          });
      final item = MediaItem(
        type: 'image',
        url: 'https://scontent.cdninstagram.com/dpr.jpg',
      );
      Widget scene(bool original) => MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(devicePixelRatio: 3),
          child: Center(
            child: SizedBox(
              width: 100,
              height: 100,
              child: CoverImage(
                item: item,
                platform: 'instagram',
                fullResolution: original,
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(scene(false));
      expect(
        (tester.widget<Image>(find.byType(Image)).image as CdnImage).cacheWidth,
        300,
      );
      await tester.pumpWidget(scene(true));
      expect(
        (tester.widget<Image>(find.byType(Image)).image as CdnImage).cacheWidth,
        isNull,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(sharedPreviewChannel, null);
    },
  );
  testWidgets(
    'real 20-image PreviewPage paints and scrolls while all image loads are blocked',
    (tester) async {
      final pending = <Completer<String?>>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(sharedPreviewChannel, (call) async {
            if (call.method == 'thumbnailAcquire') return true;
            if (call.method == 'thumbnailRead') {
              final wait = Completer<String?>();
              pending.add(wait);
              return wait.future;
            }
            return null;
          });
      final post = ParsedPost(
        platform: 'instagram',
        id: 'firstframe',
        url: 'https://www.instagram.com/p/firstframe/',
        author: PostAuthor(),
        items: List.generate(
          20,
          (i) => MediaItem(
            type: 'image',
            url: 'https://scontent.cdninstagram.com/$i.jpg',
          ),
        ),
      );
      await tester.pumpWidget(MaterialApp(home: PreviewPage(post: post)));
      // First frame has the real grid before even starting any decode.
      expect(find.byType(GridView), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(pending, isNotEmpty);
      expect(pending.length, lessThan(20));
      final images = tester
          .widgetList<Image>(find.byType(Image))
          .where((i) => i.image is CdnImage)
          .toList();
      expect(images, isNotEmpty);
      expect(images.length, lessThan(20));
      expect(
        images.every((i) => (i.image as CdnImage).cacheWidth != null),
        isTrue,
      );
      final grid = tester.widget<GridView>(find.byType(GridView));
      expect(grid.cacheExtent, 100);
      final position = tester
          .state<ScrollableState>(
            find
                .descendant(
                  of: find.byType(GridView),
                  matching: find.byType(Scrollable),
                )
                .first,
          )
          .position;
      await tester.drag(find.byType(GridView), const Offset(0, -500));
      await tester.pump();
      expect(position.pixels, greaterThan(0));
      // None of the blocked loads completed, yet both frames and input progressed.
      expect(pending.every((p) => !p.isCompleted), isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(sharedPreviewChannel, null);
    },
  );
}
