// Copyright 2026 EasySave. All rights reserved.
// v1.11 build 57, P0: a batch start is not judged by a fixed deadline.
//
// Build 56 device log (8-image post):
//   step=batch-start TIMEOUT after=10003ms -> safe default
//   step=batch-start gave up
//   …and the six remaining files kept importing, `history write files=8`.
// The user saw 「开始下载失败，请重试」, the bubble showed no x/N, and the home
// list briefly read 「0 个文件」 (the file-less placeholder of the batch).
//
// Starting a batch does one storage preflight per file (a bounded ranged
// request), so its cost grows with the post: ~10 s for 8 files. These tests run
// the real submit handler with those real timings (1.1 s per file, 10 files) and
// require that
//   * the batch is reported the moment it is queued,
//   * the bubble gets x/N from the first file on,
//   * no start-failure prompt is ever shown,
//   * the completion line is the real one.

import 'package:easysave/background/background_entry.dart' as bg;
import 'package:easysave/core/models.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

const MethodChannel _task = MethodChannel('easysave/bgtask');
const StandardMethodCodec _codec = StandardMethodCodec();
const String _link = 'https://xhslink.cn/o/pSk2BZw53J';

/// A call the handler made on the native task channel.
class _Call {
  _Call(this.method, this.arguments);

  final String method;
  final Object? arguments;

  Map<Object?, Object?> get args =>
      arguments is Map ? (arguments as Map).cast<Object?, Object?>() : const {};
}

/// The native side of the background engine (HostService).
class _Host {
  _Host();

  final List<_Call> calls = <_Call>[];

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_task, (call) async {
          calls.add(_Call(call.method, call.arguments));
          return null;
        });
  }

  Future<void> submit() async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          _task.name,
          _codec.encodeMethodCall(
            MethodCall('submit', <String, Object?>{
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

  /// Texts the user could have read: toasts, notifications and the error
  /// bubble.
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

  bool get reportedError => calls.any((call) => call.method == 'error');
}

ParsedPost _tenImagePost() => ParsedPost(
  platform: 'xhs',
  id: 'p10',
  url: _link,
  author: PostAuthor(name: 'tester'),
  items: <MediaItem>[
    for (var i = 0; i < 10; i++)
      MediaItem(type: 'image', url: 'https://sns-img.xhscdn.com/$i.jpg'),
  ],
);

/// A batch whose files are still to be downloaded.
DownloadBatch _queuedBatch(ParsedPost post, List<int> indices) => DownloadBatch(
  batchId: 'batch-slow',
  album: 'EasySave',
  postUrl: post.url,
  platform: post.platform,
  postId: post.id,
  jobs: <DownloadJob>[
    for (final index in indices)
      DownloadJob(
        key: 'k$index',
        label: 'item $index',
        filename: 'p10_$index.jpg',
        urls: <String>['https://sns-img.xhscdn.com/$index.jpg'],
        isImage: true,
        itemIndex: index + 1,
      ),
  ],
  source: DownloadBatch.sourceBackground,
);

/// Dispatch the handler's own queue so its await points run.
Future<void> _flush() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Wait for real time to pass, flushing between the steps.
Future<void> _wait(Duration total) async {
  final until = DateTime.now().add(total);
  while (DateTime.now().isBefore(until)) {
    await _flush();
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Host host;

  setUp(() {
    host = _Host()..install();
    SharedPreferencesStorePlatform.instance =
        InMemorySharedPreferencesStore.empty();
    bg.backgroundSettingsForTesting = null;
    bg.backgroundParserInitForTesting = () async {};
    bg.backgroundDownloadsInitForTesting = () async {};
    bg.backgroundParseForTesting = (url, {required source, onCacheMiss}) async =>
        _tenImagePost();
    bg.backgroundNativeTimeout = const Duration(seconds: 3);
    bg.backgroundStepTimeout = const Duration(seconds: 10);
  });

  tearDown(() {
    bg.backgroundParserInitForTesting = null;
    bg.backgroundDownloadsInitForTesting = null;
    bg.backgroundParseForTesting = null;
    bg.backgroundStartBatchForTesting = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_task, null);
    SharedPreferencesStorePlatform.instance =
        InMemorySharedPreferencesStore.empty();
  });

  /// The per-file preflight of a real batch: one bounded request per file.
  const perFile = Duration(milliseconds: 1100);
  const files = 10;

  void useSlowStart() {
    bg.backgroundStartBatchForTesting =
        (post, indices, settings, {onBatchReady}) async {
          final batch = _queuedBatch(post, indices);
          // Queued: the batch is "started" from here.
          onBatchReady?.call(batch);
          for (final job in batch.jobs) {
            await Future<void>.delayed(perFile);
            job
              ..state = JobState.done
              ..progress = 1
              ..saved = true
              ..savedTitle = job.filename;
          }
          return batch;
        };
  }

  test(
    'a slow batch start reports progress instead of failing',
    () async {
      useSlowStart();
      bg.backgroundEntry();
      await _wait(const Duration(milliseconds: 50));
      await host.submit();

      // While the preflight still runs (well before 10 s, the build 56
      // deadline) the batch is already reported and the bubble counts files.
      await _wait(const Duration(milliseconds: 2500));
      expect(
        host.logged('DOWNLOAD started $files files'),
        isTrue,
        reason: 'the batch is reported as soon as it is queued',
      );
      final early = host.bubbles.where((b) => b.total == files);
      expect(
        early,
        isNotEmpty,
        reason: 'the bubble shows x/N from the first file on',
      );
      expect(
        early.first.done,
        0,
        reason: 'the bubble starts at 0/$files, not after the preflight',
      );

      // The whole batch (about 11 s of preflight) finishes.
      await _wait(const Duration(milliseconds: 11000));
      await _wait(const Duration(milliseconds: 2500));

      expect(
        host.logged('step=batch-start ok'),
        isTrue,
        reason: 'the step reports its real duration instead of a deadline',
      );
      expect(
        host.logged('TIMEOUT'),
        isFalse,
        reason: 'no deadline judged this batch',
      );
      expect(
        host.logged('gave up'),
        isFalse,
        reason: 'build 56 gave up on a batch that was downloading',
      );
      expect(
        host.userTexts.where((text) => text.contains('开始下载失败')),
        isEmpty,
        reason: 'a slow start is not a failure',
      );
      expect(
        host.reportedError,
        isFalse,
        reason: 'no error page is opened for a running batch',
      );
      expect(
        host.userTexts.where((text) => text.contains('下载完成：$files/$files')),
        isNotEmpty,
        reason: 'the real completion is what the user gets',
      );
      expect(host.bubbles.last.error, isFalse);
      expect(host.bubbles.last.done, files);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('a start that fails after the batch was queued keeps its reporting', () async {
    bg.backgroundStartBatchForTesting =
        (post, indices, settings, {onBatchReady}) async {
          final batch = _queuedBatch(post, indices);
          onBatchReady?.call(batch);
          // The batch downloads while the enqueue of the remaining files
          // throws: nothing may turn that into a start failure.
          for (final job in batch.jobs) {
            job
              ..state = JobState.done
              ..progress = 1
              ..saved = true
              ..savedTitle = job.filename;
          }
          throw StateError('enqueue exploded');
        };
    bg.backgroundEntry();
    await _wait(const Duration(milliseconds: 50));
    await host.submit();
    await _wait(const Duration(milliseconds: 3000));

    expect(host.logged('step=batch-start late failure'), isTrue);
    expect(
      host.userTexts.where((text) => text.contains('开始下载失败')),
      isEmpty,
      reason: 'the queued batch reports its own outcome',
    );
    expect(host.reportedError, isFalse);
    expect(
      host.userTexts.where((text) => text.contains('下载完成：$files/$files')),
      isNotEmpty,
    );
  });
}
