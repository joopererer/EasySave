// Copyright 2026 EasySave. All rights reserved.
// v1.11 batch 1: local-thumbnail timeout diagnostics.
//
// Logging only: the widget keeps its own deadline, fallback and retry rules.
// These tests pin what the new fields measure — the thumbnail key, the wait,
// the in-flight count, the queue-vs-system split — and the 10 second summary.

import 'dart:async';

import 'package:easysave/core/dev_log.dart';
import 'package:easysave/services/thumbnail_diagnostics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';

import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/widgets/verified_asset_image.dart';

AssetEntity _asset(String id) => AssetEntity(
      id: id,
      typeInt: AssetType.image.index,
      width: 1000,
      height: 1000,
      title: '$id.jpg',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    DevLog.resetRecentForTesting();
    ThumbnailDiagnostics.instance.resetForTesting();
  });

  group('counters', () {
    test('a request in flight is counted until it resolves', () {
      final diagnostics = ThumbnailDiagnostics.instance;
      expect(diagnostics.inflight, 0);
      final request = diagnostics.begin('a/thumb/400x400');
      expect(diagnostics.inflight, 1);
      diagnostics.succeeded(request);
      expect(diagnostics.inflight, 0);
      expect(diagnostics.successes, 1);
    });

    test('an abandoned request leaves no trace', () {
      final diagnostics = ThumbnailDiagnostics.instance;
      final request = diagnostics.begin('b/thumb/400x400');
      diagnostics.abandon(request);
      expect(diagnostics.inflight, 0);
      expect(diagnostics.successes, 0);
      expect(diagnostics.queueTimeouts, 0);
      expect(diagnostics.systemTimeouts, 0);
    });

    test('a lone timeout is a system call timeout', () {
      final diagnostics = ThumbnailDiagnostics.instance;
      final request = diagnostics.begin('c/thumb/400x400');
      diagnostics.timedOut(request, timeout: const Duration(seconds: 5));
      expect(diagnostics.systemTimeouts, 1);
      expect(diagnostics.queueTimeouts, 0);
    });

    test('a timeout behind an unresolved request is a queue timeout', () {
      final diagnostics = ThumbnailDiagnostics.instance;
      final first = diagnostics.begin('d/thumb/400x400');
      final second = diagnostics.begin('e/thumb/400x400');
      diagnostics.timedOut(second, timeout: const Duration(seconds: 5));
      expect(diagnostics.queueTimeouts, 1);
      expect(diagnostics.systemTimeouts, 0);
      expect(diagnostics.inflight, 1);
      diagnostics.timedOut(first, timeout: const Duration(seconds: 5));
      expect(diagnostics.inflight, 0);
    });

    test('a flooded batch that times out in one sweep is a queue timeout', () {
      // Build 49: 400+ requests in flight and every one of them reported
      // system_timeout, because a whole batch resolves in the same sweep and
      // each request after the first saw an almost empty map. The crowd is
      // recorded when the request is issued.
      final diagnostics = ThumbnailDiagnostics.instance;
      final batch = [
        for (var i = 0; i < 400; i++) diagnostics.begin('flood-$i/thumb/400x400'),
      ];
      for (final request in batch) {
        diagnostics.timedOut(request, timeout: const Duration(seconds: 5));
      }
      expect(diagnostics.inflight, 0);
      expect(diagnostics.queueTimeouts, 399);
      expect(diagnostics.systemTimeouts, 1,
          reason: 'only the first request of the burst was alone');
    });

    test('the same request only ever produces one outcome', () {
      final diagnostics = ThumbnailDiagnostics.instance;
      final request = diagnostics.begin('f/thumb/400x400');
      diagnostics.timedOut(request, timeout: const Duration(seconds: 5));
      diagnostics.succeeded(request);
      diagnostics.failed(request);
      expect(diagnostics.successes, 0);
      expect(diagnostics.systemTimeouts, 1);
      expect(diagnostics.decodeErrors, 0);
    });
  });

  group('log lines', () {
    test('a timeout names the key, the wait and the queue crowd', () async {
      final diagnostics = ThumbnailDiagnostics.instance;
      diagnostics.begin('older/thumb/400x400');
      final request = diagnostics.begin('key-123/thumb/400x400');
      diagnostics.timedOut(request, timeout: const Duration(seconds: 5));
      await Future<void>.delayed(Duration.zero);

      final lines = DevLog.recentLines(50);
      final timeoutLine = lines.firstWhere(
        (line) => line.contains('queue_timeout'),
      );
      expect(timeoutLine, contains('key=key-123/thumb/400x400'));
      expect(timeoutLine, contains('kind=thumb'));
      expect(timeoutLine, contains('waited_ms='));
      expect(timeoutLine, contains('timeout_ms=5000'));
      expect(timeoutLine, contains('older_unresolved=1'));
      expect(timeoutLine, contains('concurrent_at_issue=2'));
      expect(timeoutLine, contains('inflight='));
    });

    test('a decode failure keeps the old event name and adds the key',
        () async {
      final diagnostics = ThumbnailDiagnostics.instance;
      final request = diagnostics.begin('broken/thumb/400x400');
      diagnostics.failed(request);
      await Future<void>.delayed(Duration.zero);

      final line = DevLog.recentLines(50)
          .firstWhere((line) => line.contains('local_decode_failed'));
      expect(line, contains('reason=decode'));
      expect(line, contains('key=broken/thumb/400x400'));
    });
  });

  group('window summary', () {
    test('a burst that ends inside the window is summarised right away', () {
      // This is the real device path build 49 never took: the batch was issued
      // at once, everything gave up at 5s, the map emptied before the first
      // 10s tick and the old code cancelled the timer — no summary ever.
      final diagnostics = ThumbnailDiagnostics.instance;
      final ok = diagnostics.begin('g/thumb/400x400');
      diagnostics.succeeded(ok);
      final timedOut = diagnostics.begin('h/thumb/400x400');
      diagnostics.timedOut(timedOut, timeout: const Duration(seconds: 5));

      final summaries = DevLog.recentLines(50)
          .where((line) => line.contains('window_s=10'))
          .toList();
      expect(summaries, hasLength(2), reason: 'one per finished burst');
      expect(summaries.first, contains('ok=1'));
      expect(summaries.first, contains('max_inflight=1'));
      expect(summaries.first, contains('inflight=0'));
      expect(summaries.last, contains('timeout=1'));
      expect(summaries.last, contains('system=1'));
      expect(summaries.last, contains('avg_ms='));
    });

    testWidgets('the 10 second timer keeps reporting while work is in flight',
        (tester) async {
      final diagnostics = ThumbnailDiagnostics.instance;
      final leftover = diagnostics.begin('kept/thumb/400x400');
      await tester.pump(ThumbnailDiagnostics.window);

      final first = DevLog.recentLines(50)
          .firstWhere((line) => line.contains('window_s=10'));
      expect(first, contains('ok=0'));
      expect(first, contains('inflight=1'));

      DevLog.resetRecentForTesting();
      await tester.pump(ThumbnailDiagnostics.window);
      final second = DevLog.recentLines(50)
          .firstWhere((line) => line.contains('window_s=10'));
      expect(second, contains('inflight=1'), reason: 'still open');

      // The last one going away closes the window and stops the timer.
      diagnostics.timedOut(leftover, timeout: const Duration(seconds: 5));
      final last = DevLog.recentLines(50)
          .lastWhere((line) => line.contains('window_s=10'));
      expect(last, contains('timeout=1'));
      expect(last, contains('system=1'));
      expect(last, contains('inflight=0'));
    });
  });

  group('widget wiring (behaviour unchanged)', () {
    setUp(() {
      VerifiedAssetImage.resetKnownPresentForTesting();
      GalleryLocatorService.instance.presenceProbeForTesting = (_) async => true;
    });

    tearDown(() {
      VerifiedAssetImage.existenceForTesting = null;
      VerifiedAssetImage.providerForTesting = null;
    });

    testWidgets('a stuck thumbnail still falls back and is logged with its key',
        (tester) async {
      final stuck = Completer<bool>();
      VerifiedAssetImage.existenceForTesting = (_) => stuck.future;
      VerifiedAssetImage.providerForTesting =
          (asset, original, _) => _NeverLoadingProvider(asset.id);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 80,
            height: 80,
            child: VerifiedAssetImage(
              _asset('stuck-1'),
              fallback: const ColoredBox(
                key: ValueKey('fallback'),
                color: Color(0xFF00FF00),
              ),
            ),
          ),
        ),
      ));
      expect(find.byKey(const ValueKey('fallback')), findsNothing);
      expect(ThumbnailDiagnostics.instance.inflight, 1);

      await tester.pump(kLocalThumbnailTimeout + const Duration(milliseconds: 1));
      await tester.pump();

      // The fallback behaviour is exactly the pre-v1.11 one.
      expect(find.byKey(const ValueKey('fallback')), findsOneWidget);
      expect(ThumbnailDiagnostics.instance.systemTimeouts, 1);
      expect(ThumbnailDiagnostics.instance.inflight, 0);

      final line = DevLog.recentLines(80)
          .firstWhere((line) => line.contains('system_timeout'));
      expect(line, contains('key=stuck-1/thumb/400x400'));
      await tester.pumpAndSettle(const Duration(milliseconds: 1));
    });
  });
}

/// An image provider that never produces a frame.
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
  ) =>
      OneFrameImageStreamCompleter(Completer<ImageInfo>().future);
}
