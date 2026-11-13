// Copyright 2026 EasySave. All rights reserved.
// v1.11 batch 3: every download path must survive a network that is not there.
//
// Build 50 device report: in airplane mode a TikTok video (an in-process
// `SessionMediaDownload`, the site's `transport: session`) failed on the first
// attempt as `reason=CONTENT`, the batch ended with `files=0`, a failure
// snapshot was written, and nothing continued when the connection came back.
// The background downloader never did that — it stays enqueued and resumes by
// itself — so the in-app path is brought to the same behaviour:
//
//   * no connection is not a verdict on the media: it is never `CONTENT`;
//   * the file waits ([JobState.waitingNetwork]), the UI says so, and it
//     continues by itself when the connection returns;
//   * a wait spends no attempt, records no failure and takes no snapshot;
//   * the preflight line states the outcome it really reached, so `size=-1` is
//     never printed next to `result=ok`.

import 'dart:io';
import 'dart:typed_data';

import 'package:background_downloader/background_downloader.dart';
import 'package:easysave/core/dev_log.dart';
import 'package:easysave/core/media_request.dart';
import 'package:easysave/services/download_claims.dart';
import 'package:easysave/services/download_failure_snapshots.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/media_header_service.dart';
import 'package:easysave/services/media_request_policy.dart';
import 'package:easysave/services/network_status.dart';
import 'package:easysave/services/session_media_download.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _videoUrl = 'https://v16-webapp.tiktok.com/clip.mp4';
const _imageUrl = 'https://sns-img-bd.xhscdn.com/a.jpg';

class _FakePaths extends PathProviderPlatform {
  _FakePaths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
}

/// A transfer whose outcome the test scripts: it either writes a byte and
/// finishes, or fails with the given exception.
class _ScriptedTransfer implements SessionTransfer {
  _ScriptedTransfer({this.failure});

  final SessionDownloadException? failure;
  int calls = 0;
  bool cancelled = false;
  final urls = <String>[];

  @override
  Future<void> download({
    required String url,
    required File destination,
    Future<String> Function()? readCookie,
    MediaRequestPolicy? policy,
    MediaRequestResource? resource,
    required void Function(double progress) onProgress,
  }) async {
    calls++;
    urls.add(url);
    final error = failure;
    if (error != null) throw error;
    await destination.parent.create(recursive: true);
    await destination.writeAsBytes(Uint8List(64));
    onProgress(1);
  }

  @override
  Future<void> cancel() async {
    cancelled = true;
  }
}

DownloadBatch _batch(String id, String platform, String postId, List<DownloadJob> jobs) =>
    DownloadBatch(
      batchId: id,
      album: 'EasySave',
      postUrl: 'https://www.tiktok.com/@/video/$postId',
      platform: platform,
      postId: postId,
      title: 'Post',
      itemsJson: '[]',
      postItemCount: jobs.length,
      jobs: jobs,
    );

DownloadJob _videoJob(String id) => DownloadJob(
  key: '$id-1',
  label: '视频 1',
  filename: '${id}_1.mp4',
  urls: const [_videoUrl],
  isImage: false,
  itemIndex: 1,
);

DownloadJob _imageJob(String id) => DownloadJob(
  key: '$id-1',
  label: '图片 1',
  filename: '${id}_1.jpg',
  urls: const [_imageUrl],
  isImage: true,
  itemIndex: 1,
);

/// Waits until [condition] holds, so an unawaited resume can be observed
/// without sleeping for a fixed time.
Future<void> _until(bool Function() condition, {String? reason}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail(reason ?? 'condition not reached');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final manager = DownloadManager.instance;
  final locator = GalleryLocatorService.instance;
  late HistoryDb db;
  late Directory temp;
  late Directory support;
  late Directory snapshots;
  final logs = <String>[];

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    support = await Directory.systemTemp.createTemp('easysave_support_net');
    PathProviderPlatform.instance = _FakePaths(support.path);
  });
  tearDownAll(() async {
    // A finished batch kicks off an auto backup (unawaited); give it time to
    // finish before the support directory goes away.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    try {
      if (await support.exists()) await support.delete(recursive: true);
    } on FileSystemException {
      // The backup writer still holds a file: a temp directory left behind is
      // not worth failing this suite over.
    }
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    SiteRegistry.useBuiltin();
    DevLog.resetRecentForTesting();
    NetworkStatus.instance.resetForTesting();
    manager.clearBatchesForTesting();
    HistoryDb.resetInstanceForTesting();
    db = await HistoryDb.instance(dbPath: ':memory:');
    HistoryDb.setInstanceForTesting(db);
    await db.clear();
    locator.resetForTesting();
    locator.nativeIndexReaderForTesting =
        (_) async => {'permission': 'denied', 'items': []};
    MediaHeaderService.headerReader = (_, _) async => Uint8List(0);
    temp = await Directory.systemTemp.createTemp('easysave_net');
    snapshots = await Directory.systemTemp.createTemp('easysave_snapshots');
    DownloadFailureSnapshots.directoryForTesting = snapshots;
    manager.tempRootForTesting = () async => temp;
    manager.historyWriterForTesting = (_, _, _) async {};
    manager.gallerySaveForTesting = (path, job) async => (
      mediaId: 'm-${job.itemIndex}',
      title: job.filename,
      relativePath: 'Pictures/EasySave/',
    );
    logs.clear();
    debugPrint = (message, {wrapWidth}) => logs.add(message ?? '');
    // The app installs this listener from main(); the test installs the same
    // one so the automatic resume is exercised, not simulated.
    manager.attachNetworkListenerForTesting();
  });

  tearDown(() async {
    debugPrint = debugPrintThrottled;
    for (final b in await manager.liveBatches()) {
      if (!b.isTerminal) await manager.cancelBatch(b);
      await DownloadClaims.release(b.batchId);
    }
    manager
      ..gallerySaveForTesting = null
      ..historyWriterForTesting = null
      ..sessionTransferForTesting = null
      ..enqueueForTesting = null
      ..contentLengthProbeForTesting = null
      ..tempRootForTesting = null;
    MediaHeaderService.headerReader = null;
    manager.clearBatchesForTesting();
    locator.resetForTesting();
    HistoryDb.resetInstanceForTesting();
    DownloadFailureSnapshots.directoryForTesting = null;
    NetworkStatus.instance.resetForTesting();
    if (await temp.exists()) await temp.delete(recursive: true);
    try {
      if (await snapshots.exists()) await snapshots.delete(recursive: true);
    } on FileSystemException {
      // The snapshot writer may still hold the file; the temp root above is
      // what the test owns.
    }
  });

  /// No download path may ever call a media file a content failure when the
  /// reason was the connection.
  void expectNoContentFailure() {
    final text = logs.join('\n');
    expect(text, isNot(contains('reason=CONTENT')),
        reason: 'a dead connection is not a verdict on the media');
    expect(text, isNot(contains('reason=TRANSFER')),
        reason: 'the transfer never happened');
    expect(
      DevLog.recentLines(400).where((l) => l.contains('item failed')).toList(),
      isEmpty,
      reason: 'a wait is not a failure, so the item never reports one',
    );
  }

  group('TikTok (in-process session transfer)', () {
    test('starting offline parks the file, and the connection resumes it',
        () async {
      final job = _videoJob('tiktok-offline');
      final batch = _batch('tiktok-offline', 'tiktok', '7675360280372595989', [job]);
      manager.setBatchForTesting(batch);
      final transfer = _ScriptedTransfer();
      manager.sessionTransferForTesting = () => transfer;

      NetworkStatus.instance.setOnlineForTesting(false);
      job.state = JobState.paused;
      await manager.resumeBatch(batch);

      expect(job.state, JobState.waitingNetwork);
      expect(batch.waitingForNetwork, isTrue);
      expect(batch.isTerminal, isFalse, reason: 'waiting is not an end state');
      expect(transfer.calls, 0, reason: 'no transfer is attempted offline');
      expect(job.attempts, 0, reason: 'a wait spends no attempt');
      expect(batch.failedCount, 0);
      expectNoContentFailure();
      expect(await DownloadFailureSnapshots.list(), isEmpty,
          reason: 'a waiting batch takes no snapshot');

      NetworkStatus.instance.setOnlineForTesting(true);
      await _until(() => job.state == JobState.done,
          reason: 'the file continues by itself once the connection is back');

      expect(transfer.calls, 1);
      expect(job.attempts, 1, reason: 'the one real transfer is the one attempt');
      expect(batch.failedCount, 0);
      expect(await DownloadFailureSnapshots.list(), isEmpty);
    });

    test('a connection that drops mid-transfer waits instead of failing',
        () async {
      final job = _videoJob('tiktok-drop');
      final batch = _batch('tiktok-drop', 'tiktok', '7675360280372595990', [job]);
      manager.setBatchForTesting(batch);
      var attempt = 0;
      final transfers = <_ScriptedTransfer>[];
      manager.sessionTransferForTesting = () {
        final transfer = _ScriptedTransfer(
          failure: attempt++ == 0
              ? const SessionDownloadException(
                  networkUnavailableMessage,
                  network: true,
                )
              : null,
        );
        transfers.add(transfer);
        return transfer;
      };

      job.state = JobState.paused;
      await manager.resumeBatch(batch);
      await _until(() => job.isWaitingForNetwork,
          reason: 'a network failure parks the file');

      expect(job.state, JobState.waitingNetwork);
      expect(job.attempts, 0, reason: 'the refused attempt is refunded');
      expect(job.error, isNull, reason: 'a wait writes no error text');
      expect(batch.failedCount, 0);
      expectNoContentFailure();

      // The connection goes away and comes back, as on the device.
      NetworkStatus.instance.setOnlineForTesting(false);
      NetworkStatus.instance.setOnlineForTesting(true);
      await _until(() => job.state == JobState.done,
          reason: 'the second transfer succeeds');

      expect(transfers.length, 2);
      expect(job.attempts, 1);
      expect(batch.failedCount, 0);
      expect(await DownloadFailureSnapshots.list(), isEmpty);
    });

    test('a network failure while the system claims a connection still parks '
        'the file and never names the media', () async {
      final job = _videoJob('tiktok-flaky');
      final batch = _batch('tiktok-flaky', 'tiktok', '7675360280372595991', [job]);
      manager.setBatchForTesting(batch);
      manager.sessionTransferForTesting = () => _ScriptedTransfer(
        failure: const SessionDownloadException(
          networkUnavailableMessage,
          network: true,
        ),
      );

      job.state = JobState.paused;
      await manager.resumeBatch(batch);
      await _until(() => job.isWaitingForNetwork);

      // The wait has its own clock: no connectivity event will ever come.
      expect(job.state, JobState.waitingNetwork);
      expect(job.attempts, 0);
      expectNoContentFailure();
    });
  });

  group('background downloader path', () {
    test('starting offline still queues natively and says why the preflight '
        'has no size', () async {
      final job = _imageJob('bg-offline');
      final batch = _batch('bg-offline', 'xhs', '6af1ad13000000003400572d', [job]);
      manager.setBatchForTesting(batch);
      var enqueued = 0;
      manager.enqueueForTesting = (_, _) async => enqueued++;

      NetworkStatus.instance.setOnlineForTesting(false);
      job.state = JobState.paused;
      await manager.resumeBatch(batch);

      // The native queue waits offline on its own (build 49), so it is still
      // enqueued; only the size probe cannot run.
      expect(enqueued, 1);
      final text = logs.join('\n');
      expect(text, contains('preflight'));
      expect(text, contains('size=-1'));
      expect(text, contains('result=unknown reason=offline'));
      expect(
        RegExp(r'preflight[^\n]*size=-1[^\n]*result=ok').hasMatch(text),
        isFalse,
        reason: 'a check that could not run must not report ok',
      );
    });

    test('a connection failure reported while offline parks the file and the '
        'network resumes it', () async {
      final job = _imageJob('bg-drop');
      final batch = _batch('bg-drop', 'xhs', '6af1ad13000000003400572e', [job]);
      manager.setBatchForTesting(batch);
      var enqueued = 0;
      manager.enqueueForTesting = (_, _) async => enqueued++;
      NetworkStatus.instance.setOnlineForTesting(false);
      job.attempts = 1;

      await manager.taskFailureForTesting(
        batch,
        job,
        TaskStatusUpdate(
          DownloadTask(taskId: 'bg-drop-1-try1', url: _imageUrl, filename: 'a.jpg'),
          TaskStatus.failed,
          TaskConnectionException('Failed host lookup: media.example'),
        ),
      );

      expect(job.state, JobState.waitingNetwork);
      expect(job.attempts, 0, reason: 'the attempt is refunded, not spent');
      expect(enqueued, 0, reason: 'nothing is asked again while offline');
      expect(batch.failedCount, 0);
      expectNoContentFailure();

      NetworkStatus.instance.setOnlineForTesting(true);
      await _until(() => enqueued == 1,
          reason: 'the file is enqueued again when the connection returns');
      expect(job.state, isNot(JobState.failed));
    });

    test('a connection that never succeeds ends as NETWORK, never CONTENT',
        () async {
      final job = _imageJob('bg-giveup');
      final batch = _batch('bg-giveup', 'xhs', '6af1ad13000000003400572f', [job]);
      manager.setBatchForTesting(batch);
      manager.enqueueForTesting = (_, _) async {};
      job.attempts = 3;

      await manager.taskFailureForTesting(
        batch,
        job,
        TaskStatusUpdate(
          DownloadTask(taskId: 'bg-giveup-1-try3', url: _imageUrl, filename: 'a.jpg'),
          TaskStatus.failed,
          TaskConnectionException('Failed host lookup: media.example'),
        ),
      );

      expect(job.state, JobState.failed);
      expect(job.errorCode, networkFailureCode);
      expect(shortFailureReason(job), '网络不可用');
      final line = failedJobLogLine(batch, job);
      expect(line, contains('reason=NETWORK'));
      expect(line, isNot(contains('reason=CONTENT')));
    });
  });
}
