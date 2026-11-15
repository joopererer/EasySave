// Copyright 2026 EasySave. All rights reserved.
// v1.11 batch 3: the two timing lines and what their fields mean.
//
// [ModeSwitch]  from / to            the view left and the view entered
//               first_frame_ms       switch → the new view's first frame
//               visible_ready_ms     switch → every visible thumbnail resolved
//               cache_hit            thumbnails already decoded in the cache
//               cache_miss           thumbnails that needed a request
//               local_requests       native thumbnail requests issued
// [ViewerImage] index                the item's own index in the post
//               placeholder_ms       viewer opened → low-res placeholder
//               full_ms              viewer opened → full-resolution frame
//               source               local (album) or remote (CDN)

import 'dart:convert';
import 'dart:io';

import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/perf_trace.dart';
import 'package:easysave/services/thumbnail_diagnostics.dart';
import 'package:easysave/widgets/gallery_browser.dart';
import 'package:easysave/widgets/verified_asset_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _postUrl = 'https://www.xiaohongshu.com/explore/2118566677374022101';

class _LocalAsset extends AssetEntity {
  _LocalAsset({required super.id})
    : super(
        typeInt: AssetType.image.index,
        width: 1080,
        height: 1440,
        title: 'local.jpg',
      );

  @override
  Future<File?> get file async => null;
}

List<String> _lines = <String>[];

void _collect() =>
    PerfTrace.sinkForTesting = (tag, message) => _lines.add('$tag $message');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _lines = <String>[];
    PerfTrace.sinkForTesting = null;
    ThumbnailDiagnostics.instance.resetForTesting();
    SharedPreferences.setMockInitialValues({});
    VerifiedAssetImage.resetKnownPresentForTesting();
    GalleryLocatorService.instance
      ..resetForTesting()
      ..presenceProbeForTesting = (_) async => true;
  });

  tearDown(() {
    PerfTrace.sinkForTesting = null;
    ThumbnailDiagnostics.instance.resetForTesting();
    GalleryLocatorService.instance.resetForTesting();
    VerifiedAssetImage.existenceForTesting = null;
  });

  group('the ModeSwitch line', () {
    test('waits for the visible thumbnails and counts them', () {
      _collect();
      final probe = ModeSwitchProbe(from: 'posts', to: 'all');
      final request = ThumbnailDiagnostics.instance.begin('1/thumb/400x400');

      probe.firstFrame();
      expect(_lines, isEmpty, reason: 'a thumbnail is still being fetched');

      ThumbnailDiagnostics.instance.succeeded(request);
      expect(_lines, hasLength(1));
      expect(
        _lines.single,
        startsWith('ModeSwitch from=posts to=all first_frame_ms='),
      );
      expect(_lines.single, contains('visible_ready_ms='));
      expect(_lines.single, contains('cache_hit=0 cache_miss=0'));
      expect(_lines.single, contains('local_requests=1'));
    });

    test('reports a cached view with no requests of its own', () {
      _collect();
      final probe = ModeSwitchProbe(from: 'creators', to: 'posts');
      ThumbnailDiagnostics.instance
        ..noteCacheHit()
        ..noteCacheHit()
        ..noteCacheHit();

      probe.firstFrame();

      expect(_lines, hasLength(1));
      expect(_lines.single, contains('cache_hit=3 cache_miss=0'));
      expect(_lines.single, contains('local_requests=0'));
    });

    test('counts only what happened inside the window', () {
      ThumbnailDiagnostics.instance
        ..noteCacheHit()
        ..noteCacheMiss();
      _collect();
      final probe = ModeSwitchProbe(from: 'posts', to: 'creators');
      ThumbnailDiagnostics.instance.noteCacheMiss();
      probe.firstFrame();

      expect(_lines.single, contains('cache_hit=0 cache_miss=1'));
    });

    test('a switch left before it settled still reports one line', () {
      _collect();
      final probe = ModeSwitchProbe(from: 'posts', to: 'all');
      final request = ThumbnailDiagnostics.instance.begin('1/thumb/400x400');
      probe.firstFrame();
      probe.dispose();
      ThumbnailDiagnostics.instance.succeeded(request);

      expect(_lines, hasLength(1));
      expect(_lines.single, startsWith('ModeSwitch from=posts to=all'));
      expect(
        _lines.single,
        contains('superseded=1'),
        reason: 'the switch happened; the line says it did not settle',
      );
    });

    test(
      'a switch whose thumbnails never arrive reports at its deadline',
      () async {
        _collect();
        final probe = ModeSwitchProbe(
          from: 'posts',
          to: 'all',
          deadline: const Duration(milliseconds: 30),
        );
        ThumbnailDiagnostics.instance.begin('1/thumb/400x400');
        probe.firstFrame();
        expect(_lines, isEmpty, reason: 'still inside the window');

        await Future<void>.delayed(const Duration(milliseconds: 80));

        expect(_lines, hasLength(1));
        expect(_lines.single, contains('timed_out=1'));
        expect(_lines.single, contains('settled=0'));
      },
    );

    test('an unrelated request cannot keep the line open', () {
      _collect();
      // A thumbnail of another surface that is in flight when the switch
      // starts and stays in flight the whole time.
      final other = ThumbnailDiagnostics.instance.begin('9/thumb/400x400');
      final probe = ModeSwitchProbe(from: 'creators', to: 'posts');
      probe.firstFrame();

      expect(
        _lines,
        hasLength(1),
        reason: 'the window only waits for the requests it issued',
      );
      expect(_lines.single, contains('local_requests=0'));
      expect(ThumbnailDiagnostics.instance.inflight, 1);
      ThumbnailDiagnostics.instance.abandon(other);
    });
  });

  group('the ViewerImage line', () {
    test('reports both frames from the same start', () {
      _collect();
      final probe = ViewerImageProbe(index: 2, source: 'local')
        ..placeholderShown()
        ..fullShown();

      expect(_lines, hasLength(1));
      expect(_lines.single, startsWith('ViewerImage index=2 placeholder_ms='));
      // The probe refuses a second line for the same page.
      probe.fullShown();
      expect(_lines, hasLength(1));
    });

    test('a still without a placeholder says so', () {
      _collect();
      ViewerImageProbe(index: 0, source: 'local').fullShown();
      expect(_lines.single, contains('placeholder_ms=-1'));
    });

    test('a full image that never arrives is reported as -1', () {
      _collect();
      ViewerImageProbe(index: 1, source: 'remote').failed();
      expect(_lines.single, contains('full_ms=-1 source=remote'));
    });

    test('leaving the page before the full frame is reported as -2', () {
      _collect();
      ViewerImageProbe(index: 3, source: 'local').dispose();
      expect(_lines.single, contains('full_ms=-2'));
    });
  });

  group('the viewer emits the line', () {
    testWidgets('a local still reports index, placeholder and full frame', (
      tester,
    ) async {
      _collect();
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
      );
      VerifiedAssetImage.existenceForTesting = (_) async => true;
      VerifiedAssetImage.providerForTesting = (_, _, _) => MemoryImage(png);
      final asset = _LocalAsset(id: 'local-7');
      await tester.pumpWidget(
        MaterialApp(
          home: GalleryBrowserPage(
            items: [
              GalleryBrowserItem(
                index: 7,
                type: 'image',
                url: '',
                asset: asset,
                status: FileStatus.found,
              ),
            ],
            authorName: 'a',
            title: 't',
            platform: 'xhs',
            postUrl: _postUrl,
          ),
        ),
      );
      await tester.runAsync(() async {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 60));
        await tester.pump();
      });
      await tester.pumpAndSettle();

      final line = _lines.where((l) => l.startsWith('ViewerImage ')).toList();
      expect(line, hasLength(1));
      expect(line.single, contains('index=7'));
      expect(line.single, contains('source=local'));
      expect(
        line.single,
        isNot(contains('full_ms=-2')),
        reason: 'the still painted, so the line reports a real time',
      );

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
