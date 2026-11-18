import 'package:easysave/widgets/history_cards.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('DownloadingOverlay shows buttons on wide container (>= 130dp)', (tester) async {
    var paused = false;
    var cancelled = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 180,
              height: 34,
              child: DownloadingOverlay(
                progress: 0.45,
                onTogglePause: () => paused = true,
                onCancel: () => cancelled = true,
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('下载中 45%'), findsOneWidget);
    expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
    expect(find.byIcon(Icons.close), findsOneWidget);

    await tester.tap(find.byIcon(Icons.pause_rounded));
    expect(paused, isTrue);

    await tester.tap(find.byIcon(Icons.close));
    expect(cancelled, isTrue);
  });

  testWidgets('DownloadingOverlay hides action buttons on narrow container (< 130dp) without overflow', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 100,
              height: 34,
              child: DownloadingOverlay(
                progress: 0.16,
                onTogglePause: () {},
                onCancel: () {},
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('下载中 16%'), findsOneWidget);
    expect(find.byIcon(Icons.pause_rounded), findsNothing);
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
                onCancel: () {},
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('下载中 88%'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('DownloadingOverlay handles textScaleFactor 1.3 without overflow', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
          child: Scaffold(
            body: Center(
              child: SizedBox(
                width: 150,
                height: 36,
                child: DownloadingOverlay(
                  progress: 0.5,
                  waitingForNetwork: true,
                  onTogglePause: () {},
                  onCancel: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('等待网络…联网后自动继续'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

