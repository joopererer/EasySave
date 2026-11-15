// Copyright 2026 EasySave. All rights reserved.
// v1.11 batch 3: `[ModeSwitch]` must appear for a real switch on a device.
//
// Build 55 device log had no `[ModeSwitch]` line at all while `[ViewerImage]`
// was fine. The probe used to close only when *nothing in the whole app* was in
// flight, so a thumbnail request that never came back (or simply outlived the
// switch) kept it open, and a second switch dropped it. These tests go through
// the real HistoryPage switch — tap on the segmented control, the page rebuilds
// — instead of calling the probe by hand, which is what every build-55 test did.

import 'dart:convert';

import 'package:easysave/pages/history_page.dart';
import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/host_bridge.dart';
import 'package:easysave/services/perf_trace.dart';
import 'package:easysave/services/thumbnail_diagnostics.dart';
import 'package:easysave/widgets/verified_asset_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const int _postCount = 30;
const String _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==';

List<String> _lines = <String>[];

HistoryRecord _record(int index, DateTime createdAt) => HistoryRecord(
  platform: 'xhs',
  postId: 'post-$index',
  postUrl: 'https://example.test/$index',
  title: 'Post $index',
  authorName: 'author-$index',
  fileCount: 1,
  createdAt: createdAt,
  itemsJson: jsonEncode([
    {
      'type': 'image',
      'url': 'https://sns-img.xhscdn.com/$index.jpg',
      'width': 1200,
      'height': 1600,
    },
  ]),
  files: [
    HistoryFile(
      filename: 'f_$index.jpg',
      savedAt: createdAt.millisecondsSinceEpoch,
      itemIndex: 1,
      mediaId: 'media-$index',
      status: FileStatus.found,
      relativePath: 'Pictures/EasySave/',
    ),
  ],
);

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}

Future<void> pumpHistory(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  HistoryDb.resetInstanceForTesting();
  ThumbnailDiagnostics.instance.resetForTesting();
  VerifiedAssetImage.resetKnownPresentForTesting();

  final assets = <AssetEntity>[
    for (var i = 0; i < _postCount; i++)
      AssetEntity(
        id: 'media-$i',
        typeInt: AssetType.image.index,
        width: 1200,
        height: 1600,
        title: '$i.jpg',
      ),
  ];
  final locator = GalleryLocatorService.instance;
  locator.resetForTesting();
  locator.permissionReaderForTesting = () async => PermissionState.authorized;
  locator.albumReaderForTesting = () async => assets;
  locator.presenceProbeForTesting = (_) async => true;
  locator.setScannedForTesting(
    scanned: true,
    permission: PermissionState.authorized,
    assets: assets,
  );
  VerifiedAssetImage.existenceForTesting = (_) async => true;
  VerifiedAssetImage.providerForTesting = (_, _, _) =>
      MemoryImage(base64Decode(_png));

  final now = DateTime.now();
  await tester.runAsync(() async {
    final db = await HistoryDb.instance(dbPath: ':memory:');
    HistoryDb.setInstanceForTesting(db);
    await db.clear();
    for (var i = 0; i < _postCount; i++) {
      await db.upsert(_record(i, now.subtract(Duration(seconds: i))));
    }
  });
  await tester.pumpWidget(const MaterialApp(home: HistoryPage()));
  await settle(tester);
}

List<String> switchLines() =>
    _lines.where((l) => l.startsWith('ModeSwitch ')).toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    _lines = <String>[];
    PerfTrace.sinkForTesting = (tag, message) => _lines.add('$tag $message');
    HostBridge.historyRevision.value = 0;
  });

  tearDown(() {
    PerfTrace.sinkForTesting = null;
    ThumbnailDiagnostics.instance.resetForTesting();
    VerifiedAssetImage.providerForTesting = null;
    VerifiedAssetImage.existenceForTesting = null;
    GalleryLocatorService.instance.resetForTesting();
    HistoryDb.resetInstanceForTesting();
  });

  testWidgets('tapping 创作者 writes exactly one [ModeSwitch] line', (
    tester,
  ) async {
    await pumpHistory(tester);

    await tester.tap(find.byKey(const ValueKey('view_switcher_creators')));
    await settle(tester);

    final lines = switchLines();
    expect(lines, hasLength(1));
    expect(lines.single, startsWith('ModeSwitch from=posts to=creators'));
    expect(lines.single, contains('first_frame_ms='));
    expect(
      lines.single,
      isNot(contains('first_frame_ms=-1')),
      reason: 'the new view painted',
    );
    expect(
      lines.single,
      isNot(contains('timed_out=1')),
      reason: 'the thumbnails resolved inside the window',
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a request that never comes back cannot swallow the line', (
    tester,
  ) async {
    await pumpHistory(tester);

    // A thumbnail of some other surface that started earlier and never
    // finishes — build 55 kept the app-wide in-flight count above zero with
    // exactly this, and no line was written at all.
    final stuck = ThumbnailDiagnostics.instance.begin('stuck/thumb/400x400');
    expect(ThumbnailDiagnostics.instance.inflight, greaterThan(0));

    await tester.tap(find.byKey(const ValueKey('view_switcher_creators')));
    await settle(tester);

    expect(switchLines(), hasLength(1));
    ThumbnailDiagnostics.instance.abandon(stuck);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('switching twice writes one line per switch', (tester) async {
    await pumpHistory(tester);

    await tester.tap(find.byKey(const ValueKey('view_switcher_creators')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('view_switcher_all')));
    await settle(tester);

    final lines = switchLines();
    expect(lines, hasLength(2));
    expect(lines.first, startsWith('ModeSwitch from=posts to=creators'));
    expect(lines.last, startsWith('ModeSwitch from=creators to=all'));

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
