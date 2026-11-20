import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easysave/widgets/gallery_browser.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    GalleryBrowserPage.remoteSizeFetcherForTesting = null;
  });

  group('v1.12 build 75 Item C: Fullscreen info strip and details modal', () {
    test('C1: summary text formatting for image, video, and live photo', () {
      const imageInfo = MediaInfoData(
        width: 1080,
        height: 1920,
        format: 'JPEG',
        sizeBytes: 2516582, // ~2.4 MB
      );
      expect(imageInfo.summaryText(), '1080×1920 · JPEG · 2.4 MB');

      const videoInfo = MediaInfoData(
        width: 1080,
        height: 1920,
        format: 'MP4',
        sizeBytes: 15518925, // ~14.8 MB
        isVideo: true,
        durationSeconds: 32,
      );
      expect(videoInfo.summaryText(), '1080×1920 · MP4 · 14.8 MB · 00:32');

      const liveInfo = MediaInfoData(
        width: 1080,
        height: 1920,
        format: 'HEIC',
        sizeBytes: 3250586, // ~3.1 MB
        isLive: true,
      );
      expect(liveInfo.summaryText(), '1080×1920 · HEIC · 3.1 MB · 实况');

      const estimatedInfo = MediaInfoData(
        width: 1080,
        height: 1920,
        format: 'JPEG',
        sizeBytes: 2516582,
        isEstimatedSize: true,
      );
      expect(estimatedInfo.summaryText(), '1080×1920 · JPEG · 预计 2.4 MB');
    });

    testWidgets('C2: 4-second auto-collapse to ⓘ, tap ⓘ expands, tap strip opens details', (tester) async {
      final item = GalleryBrowserItem(
        index: 1,
        type: 'image',
        url: 'https://example.com/image.jpg',
        width: 1080,
        height: 1920,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GalleryBrowserPage(
              items: [item],
              authorName: 'TestAuthor',
              title: 'TestTitle',
              platform: 'xhs',
              postUrl: 'https://example.com/post',
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Initially expanded
      expect(find.byKey(const Key('browser_info_strip')), findsOneWidget);
      expect(find.byKey(const Key('browser_info_toggle')), findsNothing);

      // Advance 4 seconds to trigger collapse
      await tester.pump(const Duration(seconds: 4));
      expect(find.byKey(const Key('browser_info_strip')), findsNothing);
      expect(find.byKey(const Key('browser_info_toggle')), findsOneWidget);

      // Tap ⓘ expands back
      await tester.tap(find.byKey(const Key('browser_info_toggle')));
      await tester.pump();
      expect(find.byKey(const Key('browser_info_strip')), findsOneWidget);

      // Tap strip opens details bottom sheet
      await tester.tap(find.byKey(const Key('browser_info_strip')));
      await tester.pumpAndSettle();
      expect(find.text('媒体详情'), findsOneWidget);
      expect(find.text('1080 × 1920'), findsOneWidget);
    });

    testWidgets('C4: remote preview fetches size only for current page with 预计 label', (tester) async {
      final requestedUrls = <String>[];
      GalleryBrowserPage.remoteSizeFetcherForTesting = (url) async {
        requestedUrls.add(url);
        return 2097152; // 2 MB
      };

      final item1 = GalleryBrowserItem(
        index: 1,
        type: 'image',
        url: 'https://example.com/img1.jpg',
        width: 1080,
        height: 1920,
      );
      final item2 = GalleryBrowserItem(
        index: 2,
        type: 'image',
        url: 'https://example.com/img2.jpg',
        width: 1080,
        height: 1920,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GalleryBrowserPage(
              items: [item1, item2],
              authorName: 'TestAuthor',
              title: 'TestTitle',
              platform: 'xhs',
              postUrl: 'https://example.com/post',
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Only item1 URL was fetched, item2 URL was NOT fetched
      expect(requestedUrls, ['https://example.com/img1.jpg']);
      expect(find.textContaining('预计 2.0 MB'), findsOneWidget);
    });

    testWidgets('C5: layout safe under 1.3 text scale factor', (tester) async {
      final item = GalleryBrowserItem(
        index: 1,
        type: 'video',
        videoUrl: 'https://example.com/video.mp4',
        url: 'https://example.com/video.mp4',
        width: 1080,
        height: 1920,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
            child: Scaffold(
              body: GalleryBrowserPage(
                items: [item],
                authorName: 'LongAuthorNameHere',
                title: 'VeryLongPostTitleThatCouldCauseOverflow',
                platform: 'xhs',
                postUrl: 'https://example.com/post',
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('browser_info_strip')), findsOneWidget);
    });
  });
}

