// Copyright 2026 EasySave. All rights reserved.
// v1.11 build 58: every user-visible download number counts items, not files.
//
// Device report: an 11-item post with 8 items selected (three of them Live
// photos) showed x/11 on the floating bubble, so the user thought the wrong
// items had been picked. A Live photo's still and motion clip are two files but
// one item, and an item only counts as done when every one of its files reached
// the album — one failed half fails the item.
//
// These tests require that the bubble, the notification title, the in-app panel
// and the completion / failure notes all show the same number of items, while
// the log keeps counting files (and adds items=).

import 'package:easysave/background/background_entry.dart' as bg;
import 'package:easysave/core/models.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/widgets/download_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'test_helpers.dart';

const MethodChannel _task = MethodChannel('easysave/bgtask');
const StandardMethodCodec _codec = StandardMethodCodec();
const String _link = 'https://xhslink.cn/o/items58';

/// A post of [count] items; the indices in [liveIndices] are Live photos.
ParsedPost _post({int count = 11, Set<int> liveIndices = const {1, 3, 5}}) =>
    ParsedPost(
      platform: 'xhs',
      id: 'p$count',
      url: _link,
      author: PostAuthor(name: 'tester'),
      items: <MediaItem>[
        for (var i = 0; i < count; i++)
          if (liveIndices.contains(i))
            MediaItem(
              type: 'live',
              url: 'https://sns-img.xhscdn.com/$i.jpg',
              videoUrl: 'https://sns-video.xhscdn.com/$i.mp4',
            )
          else
            MediaItem(type: 'image', url: 'https://sns-img.xhscdn.com/$i.jpg'),
      ],
    );

/// The batch the download manager plans for [selected] of [post]: one job per
/// file, and a Live photo's still and clip share the post's item index.
DownloadBatch _batch(
  ParsedPost post,
  List<int> selected, {
  String batchId = 'items-1',
  String source = DownloadBatch.sourceMain,
}) {
  final planned = planFiles(
    post,
    selected,
    (label, seq, ext) => 'p${post.id}_${seq}_$label',
  );
  return DownloadBatch(
    batchId: batchId,
    album: 'EasySave',
    postUrl: post.url,
    platform: post.platform,
    postId: post.id,
    postItemCount: post.items.length,
    source: source,
    jobs: <DownloadJob>[
      for (final (i, file) in planned.indexed)
        DownloadJob(
          key: '${batchId}_$i',
          label: file.label,
          filename: file.filename,
          urls: file.urls,
          isImage: file.isImage,
          itemIndex: file.itemIndex,
          isLivePhoto: file.isLivePhoto,
        ),
    ],
  );
}

DownloadJob _jobOf(DownloadBatch batch, int itemIndex, {required bool image}) =>
    batch.jobs.firstWhere(
      (j) => j.itemIndex == itemIndex && j.isImage == image,
    );

void _done(DownloadJob job) => job
  ..state = JobState.done
  ..progress = 1
  ..saved = true
  ..savedTitle = job.filename;

void _failed(DownloadJob job) => job
  ..state = JobState.failed
  ..error = '下载失败';

/// A call the background handler made on the native task channel.
class _Call {
  _Call(this.method, this.arguments);

  final String method;
  final Object? arguments;

  Map<Object?, Object?> get args =>
      arguments is Map ? (arguments as Map).cast<Object?, Object?>() : const {};
}

class _Host {
  final List<_Call> calls = <_Call>[];

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_task, (call) async {
          calls.add(_Call(call.method, call.arguments));
          return null;
        });
  }

  void uninstall() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_task, null);
  }

  Future<void> submit() async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          _task.name,
          _codec.encodeMethodCall(
            MethodCall('submit', <String, Object?>{
              // mode=all: the batch is every item of the post, so the file
              // count (14) and the item count (11) differ on purpose.
              'mode': 'all',
              'urls': <String>[_link],
              'source': 'bubble',
            }),
          ),
          (_) {},
        );
  }

  List<String> get logs => [
    for (final call in calls)
      if (call.method == 'log') '${call.arguments}',
  ];

  bool logged(String needle) => logs.any((line) => line.contains(needle));

  List<String> get userTexts => [
    for (final call in calls)
      if (call.method == 'toast' || call.method == 'notify') '${call.arguments}',
  ];

  /// Every bubble update, in order: (done, total, error).
  List<({int done, int total, bool error})> get bubbles => [
    for (final call in calls)
      if (call.method == 'bubble')
        (
          done: (call.args['done'] as num?)?.toInt() ?? -1,
          total: (call.args['total'] as num?)?.toInt() ?? -1,
          error: call.args['error'] == true,
        ),
  ];

  /// Every Quick Settings tile subtitle that carried progress, in order (an
  /// idle tile sends no subtitle).
  List<String> get tiles => [
    for (final call in calls)
      if (call.method == 'tile')
        if (call.args['subtitle'] != null) '${call.args['subtitle']}',
  ];
}

Future<void> _flush() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> _wait(Duration total) async {
  final until = DateTime.now().add(total);
  while (DateTime.now().isBefore(until)) {
    await _flush();
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final manager = DownloadManager.instance;

  setUp(() {
    SharedPreferencesStorePlatform.instance =
        InMemorySharedPreferencesStore.empty();
    manager.clearBatchesForTesting();
  });

  tearDown(() {
    manager.clearBatchesForTesting();
    SharedPreferencesStorePlatform.instance =
        InMemorySharedPreferencesStore.empty();
  });

  group('the batch counts items', () {
    test('a Live photo is one item although it is two files', () {
      final batch = _batch(_post(), [0, 1, 2, 3, 4, 5, 6, 7]);
      expect(batch.jobs, hasLength(11), reason: 'eight items, three of them Live');
      expect(batch.itemTotal, 8, reason: 'the user selected eight items');
      expect(batch.itemDone, 0);
      expect(batch.itemFailed, 0);
    });

    test('no Live photo: items and files agree', () {
      final images = _batch(_post(count: 4, liveIndices: const {}), [0, 1, 2, 3]);
      expect(images.jobs, hasLength(4));
      expect(images.itemTotal, 4);

      final videos = _batch(
        ParsedPost(
          platform: 'xhs',
          id: 'v3',
          url: _link,
          author: PostAuthor(name: 'tester'),
          items: <MediaItem>[
            for (var i = 0; i < 3; i++)
              MediaItem(
                type: 'video',
                url: 'https://sns-video.xhscdn.com/$i.mp4',
              ),
          ],
        ),
        [0, 1, 2],
      );
      expect(videos.jobs, hasLength(3));
      expect(videos.itemTotal, 3);
    });

    test('a partial selection counts only the selected items', () {
      final batch = _batch(_post(), [0, 2, 4, 6, 8]);
      expect(batch.itemTotal, 5, reason: 'five of eleven items were selected');
      expect(batch.jobs, hasLength(5));
    });

    test('an item is done only when every one of its files is saved', () {
      final batch = _batch(_post(), [0, 1]);
      _done(_jobOf(batch, 1, image: true));
      expect(batch.itemDone, 1, reason: 'item 1 is a plain still');

      _done(_jobOf(batch, 2, image: true));
      expect(batch.itemDone, 1, reason: "a Live photo's still alone is not an item");

      _done(_jobOf(batch, 2, image: false));
      expect(batch.itemDone, 2);
      expect(batch.itemFailed, 0);
      expect(batch.succeeded, 3, reason: 'the file count is unchanged');
    });

    test('a failed half fails the whole item', () {
      final batch = _batch(_post(), [0, 1]);
      _done(_jobOf(batch, 2, image: true));
      _failed(_jobOf(batch, 2, image: false));

      expect(batch.itemFailed, 1, reason: 'the Live photo counts as failed');
      expect(batch.itemDone, 0, reason: 'its still alone never completes it');
      expect(batch.failedCount, 1);
      expect(batch.doneCount, 1);
    });

    test('canceling every file of an item drops it from the total', () {
      final batch = _batch(_post(), [0, 1]);
      _done(_jobOf(batch, 1, image: true));
      for (final job in batch.jobs.where((j) => j.itemIndex == 2)) {
        job.state = JobState.canceled;
      }
      expect(batch.itemTotal, 1);
      expect(batch.itemDone, 1);
    });
  });

  group('every surface shows the same numbers', () {
    test('the notification title counts items', () {
      final batch = _batch(_post(), [0, 1, 2, 3, 4, 5, 6, 7]);
      _done(_jobOf(batch, 1, image: true));
      expect(
        downloadNotificationTitle(
          done: batch.itemDone,
          total: batch.itemTotal,
          waitingForNetwork: false,
        ),
        '正在下载 1/8',
        reason: 'eleven files must never be the denominator',
      );
    });

    testWidgets('the panel headline counts items', (tester) async {
      final batch = _batch(_post(), [0, 1, 2, 3, 4, 5, 6, 7]);
      manager.setBatchForTesting(batch);
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: DownloadSheet(batchId: batch.batchId))),
      );
      expect(find.text('正在保存 0/8'), findsOneWidget);
      expect(find.text('正在保存 0/11'), findsNothing);

      // Item 1 saved, then both halves of the Live photo of item 2.
      _done(_jobOf(batch, 1, image: true));
      _done(_jobOf(batch, 2, image: true));
      manager.setBatchForTesting(batch);
      await tester.pump();
      expect(find.text('正在保存 1/8'), findsOneWidget);

      _done(_jobOf(batch, 2, image: false));
      manager.setBatchForTesting(batch);
      await tester.pump();
      expect(find.text('正在保存 2/8'), findsOneWidget);

      // The other half of item 4 fails: the panel reports items, not files.
      _failed(_jobOf(batch, 4, image: false));
      for (final job in batch.jobs.where((j) => !j.isTerminal)) {
        _failed(job);
      }
      manager.setBatchForTesting(batch);
      await tester.pump();
      // Items 3..8 failed (six items): items 1 and 2 are in the album.
      expect(find.text('6 项失败'), findsOneWidget);
      expect(find.text('8 项失败'), findsNothing,
          reason: 'eight files failed, but only six items did');
    });
  });

  group('the background engine reports items', () {
    late _Host host;

    setUp(() {
      host = _Host()..install();
      bg.backgroundSettingsForTesting = null;
      bg.backgroundParserInitForTesting = () async {};
      bg.backgroundDownloadsInitForTesting = () async {};
      bg.backgroundParseForTesting = (url, {required source, onCacheMiss}) async =>
          _post();
      bg.backgroundNativeTimeout = const Duration(seconds: 3);
      bg.backgroundStepTimeout = const Duration(seconds: 10);
    });

    tearDown(() {
      bg.backgroundParserInitForTesting = null;
      bg.backgroundDownloadsInitForTesting = null;
      bg.backgroundParseForTesting = null;
      bg.backgroundStartBatchForTesting = null;
      host.uninstall();
    });

    test(
      'the bubble, the tile and the completion note all read x/11',
      () async {
        // Eleven items, three of them Live photos: fourteen files.
        final post = _post();
        final batch = _batch(
          post,
          [for (var i = 0; i < post.items.length; i++) i],
          batchId: 'items-bg',
          source: DownloadBatch.sourceBackground,
        );
        expect(batch.jobs, hasLength(14));
        bg.backgroundStartBatchForTesting =
            (post, indices, settings, {onBatchReady}) async {
              onBatchReady?.call(batch);
              for (final job in batch.jobs) {
                await Future<void>.delayed(
                  const Duration(milliseconds: 40),
                );
                _done(job);
              }
              return batch;
            };
        bg.backgroundEntry();
        await _wait(const Duration(milliseconds: 50));
        await host.submit();
        await waitFor(
          () => host.logged('DOWNLOAD started 14 files items=11') &&
              host.bubbles.isNotEmpty &&
              host.bubbles.last.done == 11,
          description: '11 items batch completed',
        );

        expect(
          host.logged('DOWNLOAD started 14 files items=11'),
          isTrue,
          reason: 'the log keeps the file count and adds items=',
        );
        final bubbleTotals = host.bubbles.map((b) => b.total).toSet();
        expect(
          bubbleTotals,
          {11},
          reason: 'the bubble never shows fourteen for eleven items',
        );
        expect(host.bubbles.last.done, 11);
        expect(host.bubbles.last.error, isFalse);
        expect(
          host.tiles,
          everyElement(matches(RegExp(r'^\d+/11$'))),
        );
        expect(
          host.userTexts.where((t) => t.contains('下载完成：11/11 项')),
          isNotEmpty,
        );
        expect(
          host.userTexts.where((t) => t.contains('开始下载 11 项')),
          isNotEmpty,
        );
        expect(
          host.userTexts.where((t) => t.contains('个文件')),
          isEmpty,
          reason: 'no user-visible count is per file any more',
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'a failed Live half fails the item in the failure note',
      () async {
        // Two items, the second one a Live photo: three files.
        final post = _post(count: 2, liveIndices: const {1});
        final batch = _batch(
          post,
          [0, 1],
          batchId: 'items-bg-fail',
          source: DownloadBatch.sourceBackground,
        );
        expect(batch.jobs, hasLength(3));
        bg.backgroundParseForTesting = (url, {required source, onCacheMiss}) async =>
            post;
        bg.backgroundStartBatchForTesting =
            (post, indices, settings, {onBatchReady}) async {
              onBatchReady?.call(batch);
              _done(_jobOf(batch, 1, image: true));
              _done(_jobOf(batch, 2, image: true));
              _failed(_jobOf(batch, 2, image: false));
              return batch;
            };
        bg.backgroundEntry();
        await _wait(const Duration(milliseconds: 50));
        await host.submit();
        await waitFor(
          () => host.bubbles.isNotEmpty &&
              host.bubbles.last.done == 1 &&
              host.bubbles.last.error,
          description: 'failed batch finished reporting',
        );

        expect(host.bubbles.map((b) => b.total).toSet(), {2});
        expect(host.bubbles.last.done, 1);
        expect(host.bubbles.last.error, isTrue);
        expect(
          host.userTexts.where(
            (t) => t.contains('下载失败：成功 1/2 项'),
          ),
          isNotEmpty,
          reason: 'two files succeeded and one failed, but one item of each',
        );
        expect(host.logged('1 failed'), isTrue);
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });
}
