import 'dart:async';

import 'package:easysave/core/models.dart';
import 'package:easysave/pages/preview_page.dart';
import 'package:easysave/services/media_request_policy.dart';
import 'package:easysave/services/shared_preview_cache.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:easysave/widgets/gallery_browser.dart';
import 'package:easysave/widgets/shared.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// Model the declarations produced by ParseService, including the additional
// thumbnail slot introduced in build 24. No external media is requested.
MediaItem declaredItem(String platform, String host, String type, int index) {
  final source = MediaItem(
    type: type,
    url: 'https://$host/original$index.jpg',
    videoUrl: type == 'video' ? 'https://$host/video$index.mp4' : null,
    thumbnailUrl: 'https://$host/small$index.jpg',
  );
  final declarations = MediaRequestPolicy(
    SiteRegistry.current.byId(platform)!,
  ).resourcesFor(source);
  return MediaItem(
      type: source.type,
      url: source.url,
      videoUrl: source.videoUrl,
      posterUrl: source.posterUrl,
      thumbnailUrl: source.thumbnailUrl,
      requestResources: declarations,
    )
    ..cachePostId = 'preview-roundtrip'
    ..cacheItemIndex = index;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Every local media request now goes through the media load gate, which arms
  // a deadline timer. A test run must not leave a platform call hanging until
  // that deadline, so the album plugin answers immediately (with "nothing").
  const photos = MethodChannel('com.fluttercandies/photo_manager');
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(photos, (_) async => null);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(photos, null);
  });

  for (final (platform, host, types) in [
    ('instagram', 'scontent.cdninstagram.com', ['video']),
    ('instagram', 'scontent.cdninstagram.com', ['image']),
    ('instagram', 'scontent.cdninstagram.com', ['image', 'video', 'image']),
    ('xhs', 'sns-webpic-qc.xhscdn.com', ['image', 'video']),
    ('x', 'pbs.twimg.com', ['image', 'video']),
    ('tiktok', 'p16-common-sign.tiktokcdn-eu.com', ['image', 'video']),
  ]) {
    for (final ai in platform == 'instagram' ? [false, true] : [false]) {
      testWidgets(
        '$platform ${types.join('/')} ${ai ? 'AI' : 'ordinary'} actual PreviewPage fullscreen preserves authorized originals',
        (tester) async {
          SiteRegistry.useBuiltin();
          final blocked = Completer<String?>();
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(sharedPreviewChannel, (call) async {
                if (call.method == 'thumbnailAcquire') return true;
                if (call.method == 'thumbnailRead') return blocked.future;
                return null;
              });
          final post = ParsedPost(
            platform: platform,
            id: 'preview-roundtrip',
            url: 'https://example.test/post',
            author: PostAuthor(),
            aiLabel: ai ? AiLabel(text: 'AI info', source: 'platform') : null,
            items: [
              for (var i = 0; i < types.length; i++)
                declaredItem(platform, host, types[i], i),
            ],
          );
          try {
            await tester.pumpWidget(MaterialApp(home: PreviewPage(post: post)));
            await tester.pump(const Duration(milliseconds: 400));
            expect(find.descendant(of: find.byType(PreviewPage), matching: find.text('AI')),
                ai ? findsOneWidget : findsNothing);
            await tester.tapAt(
              tester.getTopLeft(find.byType(PreviewItemCover).first) +
                  const Offset(40, 40),
            );
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 400));
            final gallery = tester.widget<GalleryBrowserPage>(
              find.byType(GalleryBrowserPage),
            );
            expect(gallery.aiLabel, ai ? 'AI info' : null);
            expect(gallery.aiLabelSource, ai ? 'platform' : null);
            expect(find.descendant(of: find.byType(GalleryBrowserPage), matching: find.text('AI')),
                ai ? findsOneWidget : findsNothing);
            final policy = MediaRequestPolicy(
              SiteRegistry.current.byId(platform)!,
            );
            for (var i = 0; i < post.items.length; i++) {
              final original = post.items[i];
              final fullscreen = gallery.items[i].toMediaItem();
              // Download and bubble paths consume the parser's original item;
              // the real App route must retain exactly the same declarations.
              final originalResources = policy.resourcesFor(original);
              expect(fullscreen.thumbnailUrl, original.thumbnailUrl);
              expect(fullscreen.url, original.url);
              expect(fullscreen.videoUrl, original.videoUrl);
              expect(fullscreen.posterUrl, original.posterUrl);
              expect(
                policy.resourcesFor(fullscreen).map((r) => r.toJson()),
                originalResources.map((r) => r.toJson()),
              );
              await CdnImage(
                fullscreen,
                platform: platform,
              ).obtainKey(ImageConfiguration.empty);
              if (fullscreen.type == 'image') {
                expect(
                  CdnImage(fullscreen, platform: platform).cacheIdentity,
                  isNot(
                    CdnImage(
                      fullscreen,
                      platform: platform,
                      cacheWidth: 200,
                    ).cacheIdentity,
                  ),
                );
              }
              expect(fullscreen.cachePostId, post.id);
              expect(fullscreen.cacheItemIndex, i);
            }
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            PaintingBinding.instance.imageCache.clear();
            PaintingBinding.instance.imageCache.clearLiveImages();
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockMethodCallHandler(sharedPreviewChannel, null);
            SiteRegistry.useBuiltin();
          }
        },
      );
    }
  }
}
