// Copyright 2026 EasySave. All rights reserved.
// v1.12 build 68: card interaction, immediate icon flip, badges, and finishing display.

import 'package:easysave/core/models.dart';
import 'package:easysave/widgets/history_cards.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('5b: pause/resume toggle button immediate icon flip and small badge overlay', () {
    testWidgets('tapping flips icon in the very same frame (pause -> play)', (tester) async {
      var tapped = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DownloadingOverlay(
              progress: 0.5,
              paused: false,
              onTogglePause: () {
                tapped++;
              },
            ),
          ),
        ),
      );

      // Initially active download: shows pause icon
      expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);

      // Tap the button
      await tester.tap(find.byIcon(Icons.pause_rounded));

      // Same frame (pump without elapsed time)
      await tester.pump();

      // Must have flipped immediately to play icon!
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      expect(find.byIcon(Icons.pause_rounded), findsNothing);
      // Small progress indicator overlay inside the toggle button
      expect(
        find.descendant(
          of: find.byType(Tooltip),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      expect(tapped, 1);
    });

    testWidgets('reverts to original icon if tap throws or fails', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DownloadingOverlay(
              progress: 0.5,
              paused: false,
              onTogglePause: () {
                throw StateError('Simulated toggle failure');
              },
            ),
          ),
        ),
      );

      expect(find.byIcon(Icons.pause_rounded), findsOneWidget);

      await tester.tap(find.byIcon(Icons.pause_rounded));
      await tester.pump();

      // On error, reverts to pause icon
      expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
    });
  });

  group('5c: coverBadges position and grouping', () {
    testWidgets('video duration badge is placed at top-right, never top-left', (tester) async {
      final videoItem = MediaItem(
        type: 'video',
        url: 'https://example.com/video.mp4',
        duration: 125, // 02:05
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Stack(
                children: coverBadges(
                  context,
                  cover: videoItem,
                  itemCount: 3,
                  showInfo: true,
                ),
              ),
            ),
          ),
        ),
      );

      // Duration label 02:05 is displayed
      expect(find.text('2:05'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);

      // Badge Positioned must have top: 8, right: 8, and NO left: 8
      final positionedWidgets = tester.widgetList<Positioned>(find.byType(Positioned));
      for (final p in positionedWidgets) {
        expect(p.left, isNot(8), reason: 'Video duration must not be at left: 8');
        if (p.right == 8) {
          expect(p.top, 8);
        }
      }
    });
  });

  group('4d: finishing stage displays "正在保存到相册"', () {
    testWidgets('DownloadingOverlay shows "正在保存到相册" when isFinishing is true', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: DownloadingOverlay(
              progress: 1.0,
              isFinishing: true,
            ),
          ),
        ),
      );

      expect(find.text('正在保存到相册'), findsOneWidget);
      expect(find.text('下载中 100%'), findsNothing);
    });
  });
}
