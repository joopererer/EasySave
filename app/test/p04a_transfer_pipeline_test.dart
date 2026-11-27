import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:easysave/core/models.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/download_status_display.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/parse_service.dart';
import 'package:easysave/services/transfer_client.dart';

class FakeTransferClient extends TransferClient {
  final StreamController<TransferEvent> controller =
      StreamController<TransferEvent>.broadcast();
  final List<Map<String, dynamic>> enqueued = [];
  final List<String> paused = [];
  final List<String> resumed = [];
  final List<String> canceled = [];
  final List<String> retried = [];
  final List<Map<String, dynamic>> updatedUrls = [];
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
    int? batchTotalCount,
  }) async {
    enqueued.add({
      'jobId': jobId,
      'category': category,
      'batchId': batchId,
      'pairId': pairId,
      'url': url,
      'mime': mime,
      'policyKey': policyKey,
      'provenance': provenance,
    });
    return jobId ?? '';
  }

  @override
  Future<bool> pause(String jobId) async {
    paused.add(jobId);
    return true;
  }

  @override
  Future<bool> resume(String jobId) async {
    resumed.add(jobId);
    return true;
  }

  @override
  Future<bool> cancel(String jobId) async {
    canceled.add(jobId);
    return true;
  }

  @override
  Future<bool> retry(String jobId) async {
    retried.add(jobId);
    return true;
  }

  @override
  Future<bool> updateUrlAndResume({
    required String jobId,
    required String url,
    Map<String, String>? headers,
    String? cookie,
    List<String>? allowedCookieDomains,
    List<Map<String, dynamic>>? policyHosts,
    String? mime,
    String? policyKey,
  }) async {
    updatedUrls.add({'jobId': jobId, 'url': url});
    return true;
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late HistoryDb testDb;
  late FakeTransferClient fakeClient;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('p04a_test_');
    HistoryDb.resetInstanceForTesting();
    testDb = await HistoryDb.instance(dbPath: '${tempDir.path}/history.db');
    HistoryDb.setInstanceForTesting(testDb);
    fakeClient = FakeTransferClient();

    final dm = DownloadManager.instance;
    dm.prepareStartForTesting = () async {};
    dm.transferClientForTesting = fakeClient;
    dm.useNewTransferPipelineForTesting = true;
    dm.reparseForTesting = null;
  });

  tearDown(() async {
    final dm = DownloadManager.instance;
    dm.prepareStartForTesting = null;
    dm.transferClientForTesting = null;
    dm.useNewTransferPipelineForTesting = null;
    dm.reparseForTesting = null;
    fakeClient.dispose();
    HistoryDb.setInstanceForTesting(null);
    HistoryDb.resetInstanceForTesting();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  ParsedPost makePost({
    String id = 'p04a_post_1',
    List<MediaItem>? items,
  }) =>
      ParsedPost(
        platform: 'xhs',
        id: id,
        url: 'https://www.xiaohongshu.com/explore/$id',
        author: PostAuthor(name: 'Tester', id: 'u1'),
        title: 'Test Post $id',
        items: items ??
            [
              MediaItem(
                type: 'image',
                url: 'https://sns-webpic-qc.xhscdn.com/123456',
              ),
            ],
      );

  group('UI status mapping (new pipeline)', () {
    test('maps every transfer state to exact Chinese copy', () {
      expect(
        resolveDownloadStatus(
          transferState: 'running',
          progress: 0.42,
          totalKnown: true,
        ).label,
        '下载中 42%',
      );
      expect(
        resolveDownloadStatus(
          transferState: 'running',
          progress: 0.0,
          totalKnown: false,
        ).label,
        '下载中',
      );
      expect(
        resolveDownloadStatus(transferState: 'waiting_network').label,
        '等待网络',
      );
      expect(
        resolveDownloadStatus(
          transferState: 'storage_full',
          requiredBytes: 2 * 1024 * 1024 * 1024,
          availableBytes: 1 * 1024 * 1024 * 1024,
        ).label,
        '空间不足 · 需2.0GB，可用1.0GB',
      );
      expect(
        resolveDownloadStatus(transferState: 'interrupted').label,
        '已中断，点继续',
      );
      expect(
        resolveDownloadStatus(transferState: 'finishing').label,
        '正在保存到相册',
      );
      expect(
        resolveDownloadStatus(transferState: 'waiting_pair').label,
        '正在保存到相册',
      );
      expect(
        resolveDownloadStatus(transferState: 'paused').label,
        '已暂停',
      );
    });
  });

  group('DownloadManager new transfer pipeline (P0-4a)', () {
    test('switch off does not call TransferClient', () async {
      final dm = DownloadManager.instance;
      dm.useNewTransferPipelineForTesting = false;
      dm.enqueueForTesting = (batch, job) async {
        job.state = JobState.done;
        job.saved = true;
      };
      try {
        final post = makePost(id: 'off_post_1');
        final batch = await dm.startBatch(
          post,
          const [0],
          album: 'EasySave',
          nameFor: (_, s, _) => '${post.id}_$s',
        );
        expect(batch.usesNewTransferPipeline, isFalse);
        expect(fakeClient.enqueued, isEmpty);
      } finally {
        dm.enqueueForTesting = null;
      }
    });

    test('batch completion writes HistoryDb with mediaId and md5, and acks service', () async {
      final dm = DownloadManager.instance;
      final post = makePost(id: 'done_post_1');
      final batch = await dm.startBatch(
        post,
        const [0],
        album: 'EasySave',
        nameFor: (_, s, _) => '${post.id}_$s',
      );
      expect(batch.usesNewTransferPipeline, isTrue);
      expect(fakeClient.enqueued.length, 1);
      final jobId = fakeClient.enqueued.single['jobId'] as String;

      fakeClient.controller.add(TransferProgressEvent(
        jobId: jobId,
        bytesRead: 500,
        totalBytes: 1000,
      ));
      await Future<void>.delayed(Duration.zero);
      expect(batch.jobs.single.progress, closeTo(0.5, 0.01));

      fakeClient.controller.add(TransferCompletedEvent(
        jobId: jobId,
        mediaId: '9001',
        md5: '098f6bcd4621d373cade4e832627b4f6',
        title: 'done_post_1_1.jpg',
        fileSize: 1000,
        relativePath: 'Pictures/EasySave/',
      ));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(batch.isTerminal, isTrue);
      expect(batch.historyWritten, isTrue);
      final rec = await testDb.getByPostId('done_post_1');
      expect(rec, isNotNull);
      expect(rec!.files.single.mediaId, '9001');
      expect(rec.files.single.md5, '098f6bcd4621d373cade4e832627b4f6');
      expect(fakeClient.ackedHistory.last, contains(jobId));
    });

    test('candidate fallback re-enqueues next candidate on failure until exhausted', () async {
      final dm = DownloadManager.instance;
      final post = makePost(
        id: 'fallback_post_1',
        items: [
          MediaItem(
            type: 'image',
            url: 'https://sns-webpic-qc.xhscdn.com/first_404',
            fallbacks: ['https://sns-webpic-qc.xhscdn.com/second_ok'],
          ),
        ],
      );
      final batch = await dm.startBatch(
        post,
        const [0],
        album: 'EasySave',
        nameFor: (_, s, _) => '${post.id}_$s',
      );
      expect(fakeClient.enqueued.length, 1);
      final firstJobId = fakeClient.enqueued[0]['jobId'] as String;

      // 1st candidate fails with 404 -> triggers fallback to 2nd candidate
      fakeClient.controller.add(TransferStateChangeEvent(
        jobId: firstJobId,
        from: 'running',
        to: 'failed',
        reason: 'http_404',
        retryCount: 0,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(fakeClient.enqueued.length, 2);
      final secondJobId = fakeClient.enqueued[1]['jobId'] as String;
      expect(secondJobId, isNot(equals(firstJobId)));
      expect(batch.jobs.single.candidateIndex, 1);

      // 2nd candidate succeeds
      fakeClient.controller.add(TransferCompletedEvent(
        jobId: secondJobId,
        mediaId: '9002',
        md5: 'abc123',
        title: 'fallback_post_1_1.jpg',
        fileSize: 512,
        relativePath: 'Pictures/EasySave/',
      ));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(batch.jobs.single.state, JobState.done);
    });

    test('Live photo enqueues two jobs with identical pairId and writes paired history', () async {
      final dm = DownloadManager.instance;
      final post = makePost(
        id: 'live_post_1',
        items: [
          MediaItem(
            type: 'live',
            url: 'https://sns-webpic-qc.xhscdn.com/live_img',
            videoUrl: 'https://sns-video-bd.xhscdn.com/live_vid.mp4',
          ),
        ],
      );
      await dm.startBatch(
        post,
        const [0],
        album: 'EasySave',
        nameFor: (_, s, _) => '${post.id}_$s',
      );
      expect(fakeClient.enqueued.length, 2);
      expect(fakeClient.enqueued[0]['pairId'], 'live_post_1#1');
      expect(fakeClient.enqueued[1]['pairId'], 'live_post_1#1');

      fakeClient.controller.add(TransferCompletedEvent(
        jobId: fakeClient.enqueued[0]['jobId'] as String,
        mediaId: '9101',
        md5: 'md5_img',
        title: 'live_post_1_1.jpg',
        fileSize: 100,
        relativePath: 'Pictures/EasySave/',
      ));
      fakeClient.controller.add(TransferCompletedEvent(
        jobId: fakeClient.enqueued[1]['jobId'] as String,
        mediaId: '9102',
        md5: 'md5_vid',
        title: 'live_post_1_1.mp4',
        fileSize: 200,
        relativePath: 'Pictures/EasySave/',
      ));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final rec = await testDb.getByPostId('live_post_1');
      expect(rec, isNotNull);
      expect(rec!.files.length, 2);
      expect(rec.files.every((f) => f.pairId == 'live_post_1#1'), isTrue);
    });

    test('partial failure records saved item and downloadError', () async {
      final dm = DownloadManager.instance;
      final post = makePost(
        id: 'partial_post_1',
        items: [
          MediaItem(type: 'image', url: 'https://sns-webpic-qc.xhscdn.com/ok1'),
          MediaItem(type: 'image', url: 'https://sns-webpic-qc.xhscdn.com/fail2'),
        ],
      );
      final batch = await dm.startBatch(
        post,
        const [0, 1],
        album: 'EasySave',
        nameFor: (_, s, _) => '${post.id}_$s',
      );
      final job0 = fakeClient.enqueued[0]['jobId'] as String;
      final job1 = fakeClient.enqueued[1]['jobId'] as String;

      fakeClient.controller.add(TransferCompletedEvent(
        jobId: job0,
        mediaId: '9201',
        md5: 'md5_ok',
        title: 'partial_post_1_1.jpg',
        fileSize: 120,
        relativePath: 'Pictures/EasySave/',
      ));
      // Exhaust all candidates of job1
      for (var i = 0; i < batch.jobs[1].urls.length; i++) {
        final curId = fakeClient.enqueued.last['jobId'] as String;
        fakeClient.controller.add(TransferStateChangeEvent(
          jobId: curId,
          from: 'running',
          to: 'failed',
          reason: 'http_404',
          retryCount: 0,
        ));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(job1, isNotEmpty);
      expect(batch.isTerminal, isTrue);
      final rec = await testDb.getByPostId('partial_post_1');
      expect(rec, isNotNull);
      expect(rec!.files.length, 1);
      expect(rec.downloadError, isNotNull);
    });

    test('reresolve_required reparses post and calls updateUrlAndResume', () async {
      final dm = DownloadManager.instance;
      dm.reparseForTesting = (url) async => ParseOutcome(
            data: makePost(
              id: 'reresolve_post_1',
              items: [
                MediaItem(
                  type: 'video',
                  url: 'https://sns-video-bd.xhscdn.com/fresh_url.mp4',
                  videoUrl: 'https://sns-video-bd.xhscdn.com/fresh_url.mp4',
                ),
              ],
            ),
            rawImages: const [],
          );

      final post = makePost(
        id: 'reresolve_post_1',
        items: [
          MediaItem(
            type: 'video',
            url: 'https://sns-video-bd.xhscdn.com/expired.mp4',
            videoUrl: 'https://sns-video-bd.xhscdn.com/expired.mp4',
          ),
        ],
      );
      await dm.startBatch(
        post,
        const [0],
        album: 'EasySave',
        nameFor: (_, s, _) => '${post.id}_$s',
      );
      final jobId = fakeClient.enqueued.single['jobId'] as String;

      fakeClient.controller.add(TransferReresolveRequiredEvent(jobId: jobId));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(fakeClient.updatedUrls.length, 1);
      expect(fakeClient.updatedUrls.single['jobId'], jobId);
      expect(
        fakeClient.updatedUrls.single['url'],
        'https://sns-video-bd.xhscdn.com/fresh_url.mp4',
      );
    });

    test('reconcileTransferHistoryPending writes history once and acks idempotently', () async {
      final dm = DownloadManager.instance;
      final post = makePost(id: 'backfill_post_1');
      final batch = await dm.startBatch(
        post,
        const [0],
        album: 'EasySave',
        nameFor: (_, s, _) => '${post.id}_$s',
      );
      final jobId = fakeClient.enqueued.single['jobId'] as String;

      fakeClient.pendingHistoryToReturn = [
        TransferJobSnapshot(
          jobId: jobId,
          direction: 'download',
          state: 'done',
          retryCount: 0,
          batchId: batch.batchId,
          category: 'image',
          createdAt: 1,
          updatedAt: 2,
          mediaId: '9301',
          title: 'backfill_post_1_1.jpg',
          relativePath: 'Pictures/EasySave/',
          md5: 'md5_backfill',
          fileSize: 456,
          historyPending: true,
        ),
      ];

      await dm.reconcileTransferHistoryPending(db: testDb);
      final rec1 = await testDb.getByPostId('backfill_post_1');
      expect(rec1?.files.single.mediaId, '9301');
      expect(rec1?.files.single.md5, 'md5_backfill');
      expect(fakeClient.ackedHistory.length, 1);

      // Second call is idempotent and writes no duplicate
      await dm.reconcileTransferHistoryPending(db: testDb);
      final rec2 = await testDb.getByPostId('backfill_post_1');
      expect(rec2?.files.length, 1);
    });

    test('pauseBatch, resumeBatch, cancelBatch, retryJob route to TransferClient', () async {
      final dm = DownloadManager.instance;
      final post = makePost(id: 'ctrl_post_1');
      final batch = await dm.startBatch(
        post,
        const [0],
        album: 'EasySave',
        nameFor: (_, s, _) => '${post.id}_$s',
      );
      final jobId = fakeClient.enqueued.single['jobId'] as String;

      await dm.pauseBatch(batch);
      expect(fakeClient.paused, [jobId]);

      await dm.resumeBatch(batch);
      expect(fakeClient.resumed, [jobId]);

      await dm.cancelBatch(batch);
      expect(fakeClient.canceled, [jobId]);

      await dm.retryJob(batch, batch.jobs.single);
      expect(fakeClient.retried, [jobId]);
    });
  });
}

