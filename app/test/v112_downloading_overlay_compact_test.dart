import 'package:easysave/widgets/history_cards.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('DownloadingOverlay shows left queue trigger and right toggle button on wide container (>= 130dp)', (tester) async {
    var paused = false;
    var queueOpened = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 180,
              height: 44,
              child: DownloadingOverlay(
                progress: 0.45,
                onTogglePause: () => paused = true,
                onTapQueue: () => queueOpened = true,
              ),
            ),
          ),
        ),
      ),
    );

    // Left side: progress text and chevron
    expect(find.text('下载中 45%'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);

    // 4c: No cancel button on the card
    expect(find.byIcon(Icons.close), findsNothing);

    // Right side: pause button
    expect(find.byIcon(Icons.pause_rounded), findsOneWidget);

    // Tap left area -> triggers queue
    await tester.tap(find.text('下载中 45%'));
    expect(queueOpened, isTrue);

    // 4a: Right side toggle button touch target is >= 40x40dp
    final toggleFinder = find.byType(GestureDetector).last;
    final renderBox = tester.renderObject<RenderBox>(toggleFinder);
    expect(renderBox.size.width, greaterThanOrEqualTo(40));
    expect(renderBox.size.height, greaterThanOrEqualTo(40));

    // Tap right button -> triggers toggle pause
    await tester.tap(find.byIcon(Icons.pause_rounded));
    expect(paused, isTrue);
    await tester.pump(const Duration(milliseconds: 1300));
  });

  testWidgets('DownloadingOverlay renders on narrow container (< 130dp) without overflow', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 100,
              height: 44,
              child: DownloadingOverlay(
                progress: 0.16,
                onTogglePause: () {},
                onTapQueue: () {},
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('16%'), findsOneWidget);
    expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
    expect(find.byIcon(Icons.close), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('DownloadingOverlay compact mode renders on 76dp list thumbnail without overflow', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 76,
              height: 26,
              child: DownloadingOverlay(
                progress: 0.88,
                compact: true,
                onTogglePause: () {},
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('88%'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('DownloadingOverlay handles paused, waiting network, and storage full states', (tester) async {
    // 1. Paused state
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 180,
              height: 44,
              child: DownloadingOverlay(
                progress: 0.5,
                paused: true,
                onTogglePause: () {},
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('已暂停 50%'), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);

    // 2. Waiting network state
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 180,
              height: 44,
              child: DownloadingOverlay(
                progress: 0.5,
                waitingForNetwork: true,
                onTogglePause: () {},
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('等待网络…联网后自动继续'), findsOneWidget);

    // 3. Storage full state
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 180,
              height: 44,
              child: DownloadingOverlay(
                progress: 0.5,
                paused: true,
                failureReason: '空间不足',
                onTogglePause: () {},
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('空间不足'), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
  });

  testWidgets('DownloadingOverlay provides optimistic UI micro spinner on tap', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 180,
              height: 44,
              child: DownloadingOverlay(
                progress: 0.3,
                onTogglePause: () {},
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
    // Tap button
    await tester.tap(find.byIcon(Icons.pause_rounded));
    await tester.pump(); // Frame right after tap
    // Expect micro-spinner
    expect(find.byType(CircularProgressIndicator), findsNWidgets(2)); // main progress + micro spinner
    await tester.pump(const Duration(milliseconds: 1300));
  });
}
