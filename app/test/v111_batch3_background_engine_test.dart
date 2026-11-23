// Copyright 2026 EasySave. All rights reserved.
// v1.11 batch 3, P0: the background engine is destroyed when idle, then built
// again for the next task.
//
// Build 55 device log:
//   [V16HOST] Idle 60000ms reached → destroy engine + stopSelf
//   [V16HOST] FlutterEngine.executeDartEntrypoint(backgroundMain) called
//   [V16HOST] BG engine ready
//   [V16HOST] submit: mode=select urls=1 source=bubble
//   …and then nothing: no ShortLink, no ParseWebView, no batch start, while the
//   notification stayed on 「准备中」.
//
// The submit handler used to await steps that only worked on the first engine
// (a channel the rebuilt engine had not registered, a settings read, a plugin
// start). A step that never came back stopped the task without a line. These
// tests drive the **real** handler through the **real** channel, twice, with
// the second engine's platform side missing or silent, and require the task to
// keep going on the safe defaults.

import 'dart:async';

import 'package:easysave/background/background_entry.dart' as bg;
import 'package:easysave/core/models.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';
// The preferences plugin interface is not a direct dependency of the app: it is
// imported here only to stand in for the plugin the rebuilt engine no longer
// has.
// ignore: depend_on_referenced_packages
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

const MethodChannel _task = MethodChannel('easysave/bgtask');
const StandardMethodCodec _codec = StandardMethodCodec();
const String _link = 'https://xhslink.cn/o/pSk2BZw53J';

/// The native side of the background engine: the Dart handler is the app, this
/// is `HostService`.
class _Host {
  _Host();

  final List<String> methods = <String>[];
  final List<String> logs = <String>[];

  /// Methods of the task channel that never answer (a channel that is there
  /// but silent, e.g. a plugin still starting).
  final Set<String> silent = <String>{};

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_task, (call) {
          methods.add(call.method);
          if (call.method == 'log') logs.add('${call.arguments}');
          if (silent.contains(call.method)) return Completer<Object?>().future;
          return Future<Object?>.value();
        });
  }

  /// `submit`, exactly as [HostService] sends it to the isolate.
  Future<void> submit({String mode = 'all'}) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          _task.name,
          _codec.encodeMethodCall(
            MethodCall('submit', <String, Object?>{
              'mode': mode,
              'urls': <String>[_link],
              'source': 'bubble',
            }),
          ),
          (_) {},
        );
  }

  bool logged(String needle) => logs.any((line) => line.contains(needle));
}

/// A store that behaves like a plugin the rebuilt engine no longer has.
class _GoneStore extends SharedPreferencesStorePlatform
    with MockPlatformInterfaceMixin {
  @override
  Future<bool> clear() async => throw MissingPluginException('rebuilt engine');

  @override
  Future<Map<String, Object>> getAll() async =>
      throw MissingPluginException('rebuilt engine');

  @override
  Future<bool> remove(String key) async =>
      throw MissingPluginException('rebuilt engine');

  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      throw MissingPluginException('rebuilt engine');
}

/// A store that is registered but never answers.
class _SilentStore extends SharedPreferencesStorePlatform
    with MockPlatformInterfaceMixin {
  @override
  Future<bool> clear() => Completer<bool>().future;

  @override
  Future<Map<String, Object>> getAll() =>
      Completer<Map<String, Object>>().future;

  @override
  Future<bool> remove(String key) => Completer<bool>().future;

  @override
  Future<bool> setValue(String valueType, String key, Object value) =>
      Completer<bool>().future;
}

ParsedPost _post() => ParsedPost(
  platform: 'xhs',
  id: 'p1',
  url: _link,
  author: PostAuthor(name: 'tester'),
  items: <MediaItem>[
    MediaItem(type: 'image', url: 'https://sns-img.xhscdn.com/a.jpg'),
  ],
);

/// A batch that reports the way a finished one does, without a downloader.
DownloadBatch _finishedBatch(ParsedPost post, List<int> indices) {
  final jobs = <DownloadJob>[
    for (final index in indices)
      DownloadJob(
        key: 'k$index',
        label: 'item $index',
        filename: 'p1_$index.jpg',
        urls: <String>['https://sns-img.xhscdn.com/a.jpg'],
        isImage: true,
        itemIndex: index,
      ),
  ];
  for (final job in jobs) {
    job.state = JobState.done;
    job.saved = true;
    job.savedTitle = job.filename;
  }
  return DownloadBatch(
    batchId: 'batch-bg',
    album: 'EasySave',
    postUrl: post.url,
    platform: post.platform,
    postId: post.id,
    jobs: jobs,
    source: DownloadBatch.sourceBackground,
  );
}

/// Lets the handler run its steps, including the batch reporting delay.
Future<void> settle([
  Duration total = const Duration(milliseconds: 1400),
]) async {
  final until = DateTime.now().add(total);
  while (DateTime.now().isBefore(until)) {
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
    // The two steps that need a device: a parser update stream and the
    // downloader plugin. Only what the pipeline itself does is under test.
    bg.backgroundParserInitForTesting = () async {};
    bg.backgroundDownloadsInitForTesting = () async {};
    bg.backgroundParseForTesting =
        (url, {required source, onCacheMiss}) async => _post();
    // The batch reports itself the moment it is queued, exactly like
    // DownloadManager.startBatch does (v1.11 build 57).
    bg.backgroundStartBatchForTesting = (post, indices, settings,
        {onBatchReady}) async {
      final batch = _finishedBatch(post, indices);
      onBatchReady?.call(batch);
      return batch;
    };
    bg.backgroundNativeTimeout = const Duration(seconds: 3);
    bg.backgroundStepTimeout = const Duration(seconds: 10);
  });

  tearDown(() {
    bg.backgroundParserInitForTesting = null;
    bg.backgroundDownloadsInitForTesting = null;
    bg.backgroundParseForTesting = null;
    bg.backgroundStartBatchForTesting = null;
    bg.backgroundNativeTimeout = const Duration(seconds: 3);
    bg.backgroundStepTimeout = const Duration(seconds: 10);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_task, null);
    SharedPreferencesStorePlatform.instance =
        InMemorySharedPreferencesStore.empty();
  });

  test('the first engine parses, downloads and reports the batch', () async {
    bg.backgroundEntry();
    await settle(const Duration(milliseconds: 50));
    await host.submit();
    await waitFor(() => host.logged('DOWNLOAD done: 1/1'), description: 'first engine finishes download');

    expect(host.logged('step=received'), isTrue);
    expect(host.logged('step=settings ok'), isTrue);
    expect(host.logged('step=network'), isTrue);
    expect(host.logged('step=parse begin'), isTrue);
    expect(host.logged('step=batch-start ok'), isTrue);
    expect(host.logged('DOWNLOAD done: 1/1'), isTrue);
    await waitFor(() => host.methods.contains('idle'), description: 'first engine signals idle');
    expect(host.methods, contains('idle'));
  });

  test('a rebuilt engine whose settings plugin is gone still finishes the '
      'task', () async {
    // Engine #1 does a complete task, then goes idle and is destroyed.
    bg.backgroundEntry();
    await settle(const Duration(milliseconds: 50));
    await host.submit();
    await waitFor(() => host.logged('DOWNLOAD done: 1/1'), description: 'engine #1 finishes download');
    expect(host.logged('DOWNLOAD done: 1/1'), isTrue);
    await waitFor(() => host.methods.contains('idle'), description: 'engine #1 signals idle');
    expect(host.methods, contains('idle'));

    // Engine #2: rebuilt by HostService. Its channels are (re)registered, but
    // the settings plugin the first engine used is not there any more — the
    // exact shape of the build 55 stall.
    SharedPreferencesStorePlatform.instance = _GoneStore();
    host.logs.clear();
    bg.backgroundEntry();
    await settle(const Duration(milliseconds: 50));
    await host.submit();
    await waitFor(
      () => host.logged('step=settings FAILED') && host.logged('DOWNLOAD done: 1/1'),
      description: 'engine #2 logs settings FAILED and completes download',
    );

    expect(
      host.logged('step=settings FAILED'),
      isTrue,
      reason: 'the missing channel is named in the log',
    );
    expect(
      host.logged('step=settings ok'),
      isFalse,
      reason: 'the step is reported as failed, not as a success',
    );
    expect(host.logged('step=parse begin'), isTrue);
    expect(host.logged('step=batch-start ok'), isTrue);
    expect(
      host.logged('DOWNLOAD done: 1/1'),
      isTrue,
      reason: 'the second submit parses and downloads like the first one',
    );
    await waitFor(
      () => host.methods.where((m) => m == 'idle').length >= 2,
      description: 'engine #2 signals idle',
    );
  });

  test(
    'a settings read that never answers times out and the task goes on',
    () async {
      bg.backgroundStepTimeout = const Duration(milliseconds: 60);
      SharedPreferencesStorePlatform.instance = _SilentStore();

      bg.backgroundEntry();
      await settle(const Duration(milliseconds: 50));
      await host.submit();
      await waitFor(() => host.logged('step=batch-start ok'), description: 'engine proceeds to batch start after settings timeout');

      expect(host.logged('step=settings TIMEOUT'), isTrue);
      expect(host.logged('step=parse begin'), isTrue);
      expect(host.logged('step=batch-start ok'), isTrue);
    },
  );

  test('a channel that answers nothing cannot stop the submit', () async {
    // The task channel itself goes silent for the progress calls: the engine
    // still has to reach the batch.
    bg.backgroundNativeTimeout = const Duration(milliseconds: 40);
    host.silent.addAll(<String>{'notify', 'tile', 'bubble', 'log'});

    bg.backgroundEntry();
    await settle(const Duration(milliseconds: 50));
    await host.submit();
    await waitFor(() => host.logged('step=batch-start ok'), description: 'engine proceeds to batch start when channel silent');

    expect(host.logged('step=parse begin'), isTrue);
    expect(host.logged('step=batch-start ok'), isTrue);
  });

  test('an empty input still stops the engine', () async {
    bg.backgroundEntry();
    await settle(const Duration(milliseconds: 50));
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          _task.name,
          _codec.encodeMethodCall(
            MethodCall('submit', <String, Object?>{
              'mode': 'all',
              'text': 'no link here',
              'source': 'bubble',
            }),
          ),
          (_) {},
        );
    await waitFor(() => host.methods.contains('stop'), description: 'engine stops on empty input');

    expect(host.logged('no supported link in input'), isTrue);
    expect(host.methods, contains('stop'));
  });
}
