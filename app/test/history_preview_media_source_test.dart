import 'dart:convert';

import 'package:easysave/core/models.dart';
import 'package:easysave/pages/history_page.dart';
import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/media_request_policy.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:easysave/widgets/gallery_browser.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  final cases = <(String, MediaItem)>[
    (
      'x',
      MediaItem(
        type: 'video',
        url: 'https://video.twimg.com/video.mp4',
        posterUrl: 'https://pbs.twimg.com/poster.jpg',
      ),
    ),
    (
      'tiktok',
      MediaItem(
        type: 'video',
        url: 'https://v16-webapp-prime.tiktok.com/video.mp4',
        posterUrl: 'https://p16-common-sign.tiktokcdn-eu.com/poster.jpg',
      ),
    ),
    (
      'instagram',
      MediaItem(
        type: 'video',
        url: 'https://scontent.cdninstagram.com/poster.jpg',
        videoUrl: 'https://scontent.cdninstagram.com/video.mp4',
        thumbnailUrl: 'https://scontent.cdninstagram.com/small.jpg',
      ),
    ),
    (
      'xhs',
      MediaItem(
        type: 'live',
        url: 'https://sns-webpic-qc.xhscdn.com/image.jpg',
        videoUrl: 'https://sns-video-zl.xhscdn.com/video.mp4',
        thumbnailUrl: 'https://sns-webpic-qc.xhscdn.com/small.jpg',
      ),
    ),
  ];

  for (final (platform, media) in cases) {
    testWidgets('saved $platform opens original media, never its album filename', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      HistoryDb.resetInstanceForTesting();
      GalleryLocatorService.instance.resetForTesting();
      SiteRegistry.useBuiltin();
      final messenger = tester.binding.defaultBinaryMessenger;
      const channel = MethodChannel('com.fluttercandies/photo_manager');
      messenger.setMockMethodCallHandler(channel, (_) async => 0);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        messenger.setMockMethodCallHandler(channel, null);
        GalleryLocatorService.instance.resetForTesting();
        HistoryDb.resetInstanceForTesting();
      });
      await tester.runAsync(() async {
        final db = await HistoryDb.instance(dbPath: ':memory:');
        HistoryDb.setInstanceForTesting(db);
        await db.upsert(
          HistoryRecord(
            platform: platform,
            postId: 'saved-source',
            title: 'Open saved media',
            postUrl: 'https://example.invalid/post',
            fileCount: media.type == 'live' ? 2 : 1,
            createdAt: DateTime(2026),
            itemsJson: jsonEncode([media.toJson()]),
            files: [
              HistoryFile(
                filename: media.type == 'live'
                    ? 'album-image.jpg'
                    : 'album-video.mp4',
                savedAt: 0,
                itemIndex: 1,
                isImage: media.type == 'live',
              ),
              if (media.type == 'live')
                HistoryFile(
                  filename: 'album-motion.mp4',
                  savedAt: 0,
                  itemIndex: 1,
                  isImage: false,
                ),
            ],
          ),
        );
      });
      await tester.pumpWidget(const MaterialApp(home: HistoryPage()));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open saved media'));
      // Inspect the real pushed route without waiting for a native player or
      // remote image request to finish; those platform boundaries are unrelated
      // to the URL-set preservation this widget regression guards.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final browser = tester.widget<GalleryBrowserPage>(
        find.byType(GalleryBrowserPage),
      );
      final reopened = browser.items.single.toMediaItem();
      expect(reopened.url, media.url);
      expect(
        reopened.videoUrl,
        media.videoUrl,
        reason:
            'A local album filename is metadata, never a remote video fallback.',
      );
      expect(reopened.posterUrl, media.posterUrl);
      expect(reopened.thumbnailUrl, media.thumbnailUrl);
      expect(browser.items.single.filename, startsWith('album-'));
      expect(
        () => MediaRequestPolicy(
          SiteRegistry.current.byId(platform)!,
          logRejection: (_, _) {},
        ).resourcesFor(reopened),
        returnsNormally,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
