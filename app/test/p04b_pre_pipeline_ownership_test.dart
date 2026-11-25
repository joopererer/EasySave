import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:easysave/core/dev_log.dart';
import 'package:easysave/core/models.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/network_status.dart';
import 'package:easysave/services/transfer_client.dart';

class _FakeTransferClient extends TransferClient {
  final StreamController<TransferEvent> controller =
      StreamController<TransferEvent>.broadcast();
  final List<Map<String, dynamic>> enqueued = [];
  final List<List<String>> ackedHistory = [];
  List<TransferJobSnapshot> pendingHistoryToReturn = [];

  @override
  Stream<TransferEvent> get events => controller.stream;

  @override
  Future<String> enqueue({
    String? jobId,
    String direction = 'download',
    String category = 'image',
    String? batchId,
    String? pairId,
    String? fakePlan,
    String? url,
    Map<String, String>? headers,
    String? cookie,
    List<String>? allowedCookieDomains,
    List<Map<String, dynamic>>? policyHosts,
    String? mime,
    String? policyKey,
    Map<String, dynamic>? provenance,
  }) async {
    enqueued.add({
      'jobId': jobId,
      'batchId': batchId,
      'category': category,
    });
    return jobId ?? '';
  }

  @override
  Future<List<TransferJobSnapshot>> queryHistoryPending() async =>
      pendingHistoryToReturn;

  @override
  Future<bool> ackHistoryWritten(List<String> jobIds) async {
    ackedHistory.add(List<String>.from(jobIds));
    pendingHistoryToReturn = pendingHistoryToReturn
        .where((s) => !jobIds.contains(s.jobId))
        .toList();
    return true;
  }

  void dispose() {
    unawaited(controller.close());
  }
}

int _postSeq = 0;

ParsedPost _videoPost([String? id]) {
  final resolved = id ?? '5110_${++_postSeq}';
  return ParsedPost(
    platform: 'xiaohongshu',
    id: resolved,
    url: 'https://www.xiaohongshu.com/explore/$resolved',
    title: 'Big Video',
    author: PostAuthor(name: 'Tester'),
    items: [
      MediaItem(
        type: 'video',
        url: 'https://sns-video-bd.xhscdn.com/video_5110.mp4',
        fallbacks: const ['https://sns-video-bd.xhscdn.com/video_5110_alt.mp4'],
      ),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late HistoryDb testDb;
  late _FakeTransferClient fakeClient;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('p04b_pre_test_');
    HistoryDb.resetInstanceForTesting();
    testDb = await HistoryDb.instance(dbPath: '${tempDir.path}/history.db');
    HistoryDb.setInstanceForTesting(testDb);
    fakeClient = _FakeTransferClient();

    final dm = DownloadManager.instance;
    dm.prepareStartForTesting = () async {};
    dm.transferClientForTesting = fakeClient;
    dm.useNewTransferPipelineForTesting = true;
    dm.tempRootForTesting = () async => tempDir;
    dm.historyWriterForTesting = (db, batch, recovered) async {
      await writeBatchHistory(db, batch, recovered: recovered);
    };
  });

  tearDown(() async {
    final dm = DownloadManager.instance;
    dm.prepareStartForTesting = null;
    dm.transferClientForTesting = null;
    dm.useNewTransferPipelineForTesting = null;
    dm.tempRootForTesting = null;
    dm.historyWriterForTesting = null;
    dm.enqueueForTesting = null;
    dm.resumeForTesting = null;
    dm.pauseForTesting = null;
    dm.cancelTaskForTesting = null;
    dm.allRecordsForTesting = null;
    dm.deleteLegacyRecordsForTesting = null;
    fakeClient.dispose();
    HistoryDb.resetInstanceForTesting();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  test('DownloadBatch persists pipeline=transfer|legacy across JSON roundtrip', () {
    final transferBatch = DownloadBatch(
      batchId: 'b-transfer',
      album: 'EasySave',
      postUrl: 'https://example.com/1',
      platform: 'douyin',
      postId: '1',
      pipeline: DownloadBatch.pipelineTransfer,
      jobs: const [],
    );
    final decoded = DownloadBatch.fromJson(transferBatch.toJson());
    expect(decoded.pipeline, DownloadBatch.pipelineTransfer);
    expect(decoded.usesNewTransferPipeline, isTrue);

    final legacyBatch = DownloadBatch(
      batchId: 'b-legacy',
      album: 'EasySave',
      postUrl: 'https://example.com/2',
      platform: 'douyin',
      postId: '2',
      jobs: const [],
    );
    final decodedLegacy = DownloadBatch.fromJson(legacyBatch.toJson());
    expect(decodedLegacy.pipeline, DownloadBatch.pipelineLegacy);
    expect(decodedLegacy.usesNewTransferPipeline, isFalse);
  });

  test('single gate blocks enqueue, resume, pause, cancel for transfer batches', () async {
    final dm = DownloadManager.instance;

    var legacyEnqueueCalls = 0;
    var legacyResumeCalls = 0;
    var legacyPauseCalls = 0;
    var legacyCancelCalls = 0;

    dm.enqueueForTesting = (batch, job) async => legacyEnqueueCalls++;
    dm.resumeForTesting = (task) async {
      legacyResumeCalls++;
      return true;
    };
    dm.pauseForTesting = (task) async {
      legacyPauseCalls++;
      return true;
    };
    dm.cancelTaskForTesting = (taskId) async => legacyCancelCalls++;

    final post = _videoPost();
    final batch = await dm.startBatch(
      post,
      const [0],
      album: 'EasySave',
      nameFor: (_, s, _) => '${post.id}_$s',
    );
    expect(batch.pipeline, DownloadBatch.pipelineTransfer);
    final job = batch.jobs.first;
    final fakeTask = DownloadTask(
      taskId: job.key,
      group: batch.batchId,
      url: 'https://cdn.example.com/video_5110.mp4',
      filename: 'v.mp4',
    );

    await dm.enqueueAttemptForTesting(batch, job, source: 'unit_test');
    expect(await dm.resumeTaskForTesting(fakeTask, batch: batch, source: 'unit_test'), isFalse);
    expect(await dm.pauseTaskForTesting(fakeTask, batch: batch, source: 'unit_test'), isFalse);
    await dm.cancelTaskWithIdForTesting(job.key, batch: batch, source: 'unit_test');

    expect(legacyEnqueueCalls, 0);
    expect(legacyResumeCalls, 0);
    expect(legacyPauseCalls, 0);
    expect(legacyCancelCalls, 0);
    final logs = DevLog.recentLines(200).join('\n');
    expect(logs, contains('legacy_call_blocked batch=${batch.batchId}'));
  });

  test('network offline->online recovery makes 0 legacy calls and settles once', () async {
    final dm = DownloadManager.instance;
    dm.attachNetworkListenerForTesting();

    var legacyEnqueueCalls = 0;
    var legacyResumeCalls = 0;
    dm.enqueueForTesting = (batch, job) async => legacyEnqueueCalls++;
    dm.resumeForTesting = (task) async {
      legacyResumeCalls++;
      return true;
    };

    final post = _videoPost();
    final batch = await dm.startBatch(
      post,
      const [0],
      album: 'EasySave',
      nameFor: (_, s, _) => '${post.id}_$s',
    );
    final job = batch.jobs.first;
    final transferJobId = job.transferJobId!;

    job.state = JobState.paused;
    job.resumeStartByte = 1024;
    NetworkStatus.instance.setStatusForTesting(online: false, type: 'none');
    NetworkStatus.instance.setStatusForTesting(online: true, type: 'wifi');
    dm.triggerNetworkRecoveryForTesting();
    await dm.resumeWaitingJobsForTesting();

    expect(legacyEnqueueCalls, 0);
    expect(legacyResumeCalls, 0);

    fakeClient.controller.add(
      TransferCompletedEvent(
        jobId: transferJobId,
        mediaId: '9001',
        title: 'video_5110.mp4',
        md5: 'deadbeef',
        fileSize: 2048,
      ),
    );
    for (var i = 0; i < 40 && !batch.historyWritten; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    fakeClient.controller.add(
      TransferStateChangeEvent(
        jobId: transferJobId,
        from: 'finishing',
        to: 'done',
        retryCount: 0,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(legacyEnqueueCalls, 0);
    expect(legacyResumeCalls, 0);
    final settleCount = DevLog.recentLines(400)
        .where((line) => line.contains('batch_settle id=${batch.batchId}'))
        .length;
    expect(settleCount, 1);
  });

  test('restart reconcile makes 0 legacy calls and settles once', () async {
    final dm = DownloadManager.instance;
    final post = _videoPost();
    final batch = await dm.startBatch(
      post,
      const [0],
      album: 'EasySave',
      nameFor: (_, s, _) => '${post.id}_$s',
    );
    final transferJobId = batch.jobs.first.transferJobId!;

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('easysave_batch_${batch.batchId}');
    expect(raw, isNotNull);
    final decoded = DownloadBatch.fromJson(
      (jsonDecode(raw!) as Map).cast<String, Object?>(),
    );
    expect(decoded.pipeline, DownloadBatch.pipelineTransfer);

    fakeClient.pendingHistoryToReturn = [
      TransferJobSnapshot(
        jobId: transferJobId,
        direction: 'download',
        category: 'large_file',
        batchId: batch.batchId,
        state: 'done',
        retryCount: 0,
        createdAt: 1,
        updatedAt: 2,
        mediaId: '9002',
        title: 'video_5110.mp4',
        md5: 'cafebabe',
        fileSize: 4096,
        historyPending: true,
      ),
    ];

    var legacyEnqueueCalls = 0;
    var legacyResumeCalls = 0;
    dm.enqueueForTesting = (b, j) async => legacyEnqueueCalls++;
    dm.resumeForTesting = (t) async {
      legacyResumeCalls++;
      return true;
    };
    dm.allRecordsForTesting = (group) async => [];

    await dm.reconcileBatchForTesting(decoded);
    await dm.reconcileTransferHistoryPending(db: testDb);
    await dm.reconcileTransferHistoryPending(db: testDb);

    expect(legacyEnqueueCalls, 0);
    expect(legacyResumeCalls, 0);
    final settleCount = DevLog.recentLines(400)
        .where((line) => line.contains('batch_settle id=${batch.batchId}'))
        .length;
    expect(settleCount, 1);
    expect(fakeClient.ackedHistory.expand((e) => e), contains(transferJobId));
  });

  test('auto_resume timer and watchdog never call legacy enqueue/resume for transfer batch', () async {
    final dm = DownloadManager.instance;

    var legacyEnqueueCalls = 0;
    var legacyResumeCalls = 0;
    var legacyCancelCalls = 0;
    dm.enqueueForTesting = (b, j) async => legacyEnqueueCalls++;
    dm.resumeForTesting = (t) async {
      legacyResumeCalls++;
      return true;
    };
    dm.cancelTaskForTesting = (id) async => legacyCancelCalls++;
    dm.allRecordsForTesting = (group) async => [];

    final post = _videoPost();
    final batch = await dm.startBatch(
      post,
      const [0],
      album: 'EasySave',
      nameFor: (_, s, _) => '${post.id}_$s',
    );
    final job = batch.jobs.first;
    job.state = JobState.paused;
    job.lastProgressAt = DateTime.now().millisecondsSinceEpoch - 600000;

    await dm.runWatchdogForTesting(batch);

    final timerFired = Completer<void>();
    dm.autoResumeTimersForTesting[job.key] = Timer(
      const Duration(milliseconds: 10),
      () async {
        if (!batch.usesNewTransferPipeline) {
          await dm.enqueueAttemptForTesting(batch, job, source: 'auto_resume');
        }
        timerFired.complete();
      },
    );
    await timerFired.future;

    await dm.enqueueAttemptForTesting(batch, job, source: 'auto_resume');

    expect(legacyEnqueueCalls, 0);
    expect(legacyResumeCalls, 0);
    expect(legacyCancelCalls, 0);
  });

  test('startup cleanup cancels orphan legacy tasks and deletes temp files', () async {
    final dm = DownloadManager.instance;
    final post = _videoPost();
    final batch = await dm.startBatch(
      post,
      const [0],
      album: 'EasySave',
      nameFor: (_, s, _) => '${post.id}_$s',
    );

    final orphanDir = Directory('${tempDir.path}/easysave/${batch.batchId}');
    await orphanDir.create(recursive: true);
    final orphanFile = File('${orphanDir.path}/orphan.part');
    await orphanFile.writeAsBytes(List<int>.filled(256, 7));

    final canceledIds = <String>[];
    final deletedRecordIds = <String>[];
    dm.cancelTaskForTesting = (id) async => canceledIds.add(id);
    dm.deleteLegacyRecordsForTesting = (ids) async => deletedRecordIds.addAll(ids);
    dm.allRecordsForTesting = (group) async => group == batch.batchId
        ? [
            TaskRecord(
              DownloadTask(
                taskId: 'orphan-task-1',
                group: batch.batchId,
                url: 'https://sns-video-bd.xhscdn.com/video_5110.mp4',
                filename: 'orphan.mp4',
              ),
              TaskStatus.paused,
              0.2,
              1000,
            ),
          ]
        : [];

    final res = await dm.cleanupTransferOrphanLegacyTasksForTesting();
    expect(res.tasks, 1);
    expect(res.files, greaterThanOrEqualTo(1));
    expect(res.bytes, greaterThanOrEqualTo(256));
    expect(canceledIds, ['orphan-task-1']);
    expect(deletedRecordIds, ['orphan-task-1']);
    expect(await orphanDir.exists(), isFalse);
    expect(DevLog.recentLines(200).join('\n'), contains('legacy_orphan_cleaned'));
  });

  test('switch OFF keeps legacy DownloadManager behavior unchanged', () async {
    final dm = DownloadManager.instance;
    dm.useNewTransferPipelineForTesting = false;
    var legacyEnqueued = 0;
    dm.enqueueForTesting = (b, j) async => legacyEnqueued++;

    final post = _videoPost();
    final batch = await dm.startBatch(
      post,
      const [0],
      album: 'EasySave',
      nameFor: (_, s, _) => '${post.id}_$s',
    );
    expect(batch.pipeline, DownloadBatch.pipelineLegacy);
    expect(batch.usesNewTransferPipeline, isFalse);
    expect(legacyEnqueued, 1);
    expect(fakeClient.enqueued, isEmpty);
  });
}
