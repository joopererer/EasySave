import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:easysave/core/dev_log.dart';
import 'package:easysave/core/models.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/download_status_display.dart';
import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/transfer_client.dart';
import 'package:easysave/widgets/gallery_browser.dart';

class _P04eFakeTransferClient extends TransferClient {
  final StreamController<TransferEvent> controller =
      StreamController<TransferEvent>.broadcast();
  final List<Map<String, dynamic>> enqueued = [];
  final List<List<String>> acked = [];
  List<TransferJobSnapshot> snapshotToReturn = [];
  List<TransferJobSnapshot> pendingHistoryToReturn = [];
  final Map<String, int> _claims = {};

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
      'batchId': batchId,
      'batchTotalCount': batchTotalCount,
    });
    return jobId ?? '';
  }

  @override
  Future<bool> claimHistoryWrite(String batchId) async {
    if (_claims.containsKey(batchId)) return false;
    _claims[batchId] = 1;
    return true;
  }

  @override
  Future<bool> ackHistoryWritten(List<String> jobIds) async {
    acked.add(List<String>.from(jobIds));
    pendingHistoryToReturn = pendingHistoryToReturn
        .where((s) => !jobIds.contains(s.jobId))
        .toList();
    return true;
  }

  @override
  Future<List<TransferJobSnapshot>> snapshot() async => snapshotToReturn;

  @override
  Future<List<TransferJobSnapshot>> queryHistoryPending() async =>
      pendingHistoryToReturn;

  void dispose() {
    unawaited(controller.close());
  }
}

DownloadBatch _makeCrossEngineBatch(String batchId, String postId) {
  final job = DownloadJob(
    key: '${batchId}_0',
    label: 'video',
    filename: '$postId.mp4',
    urls: ['https://example.com/$postId.mp4'],
    isImage: false,
    itemIndex: 1,
  )
    ..state = JobState.active
    ..usesNewTransferPipeline = true
    ..transferJobId = 'xfer_${batchId}_0'
    ..transferState = 'running';
  return DownloadBatch(
    batchId: batchId,
    album: 'EasySave',
    postUrl: 'https://www.douyin.com/video/$postId',
    platform: 'douyin',
    postId: postId,
    title: 'Cross Engine Video $postId',
    source: DownloadBatch.sourceBackground,
    pipeline: DownloadBatch.pipelineTransfer,
    jobs: [job],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late HistoryDb testDb;
  late _P04eFakeTransferClient fakeClient;
  late String prevOwner;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    prevOwner = DownloadManager.owner;
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('p04e_test_');
    HistoryDb.resetInstanceForTesting();
    testDb = await HistoryDb.instance(dbPath: '${tempDir.path}/history.db');
    HistoryDb.setInstanceForTesting(testDb);
    DevLog.resetRecentForTesting();
    GalleryLocatorService.instance.resetForTesting();
    fakeClient = _P04eFakeTransferClient();

    DownloadManager.owner = DownloadBatch.sourceMain;
    final dm = DownloadManager.instance;
    dm.resetInitForTesting();
    dm.clearBatchesForTesting();
    dm.downloaderStartForTesting = () async {};
    dm.allRecordsForTesting = (_) async => [];
    dm.deleteLegacyRecordsForTesting = (_) async {};
    dm.prepareStartForTesting = () async {};
    dm.transferClientForTesting = fakeClient;
    dm.useNewTransferPipelineForTesting = true;
    dm.tempRootForTesting = () async => tempDir;
    dm.historyWriterForTesting = (db, batch, recovered) async {
      await writeBatchHistory(db, batch, recovered: recovered);
    };
  });

  tearDown(() async {
    DownloadManager.owner = prevOwner;
    final dm = DownloadManager.instance;
    dm.clearBatchesForTesting();
    dm.resetInitForTesting();
    dm.downloaderStartForTesting = null;
    dm.prepareStartForTesting = null;
    dm.transferClientForTesting = null;
    dm.useNewTransferPipelineForTesting = null;
    dm.tempRootForTesting = null;
    dm.historyWriterForTesting = null;
    dm.allRecordsForTesting = null;
    dm.deleteLegacyRecordsForTesting = null;
    GalleryLocatorService.instance.resetForTesting();
    fakeClient.dispose();
    HistoryDb.resetInstanceForTesting();
    DevLog.resetRecentForTesting();
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  group('P0-4e cross-engine settlement & immediate locate', () {
    Future<void> seedBackgroundBatch(DownloadBatch batch) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('easysave_batches', [batch.batchId]);
      await prefs.setString(
        'easysave_batch_${batch.batchId}',
        jsonEncode(batch.toJson()),
      );
    }

    Future<void> verifyImmediateLocate(String postId, String mediaId) async {
      final records = await testDb.recent(limit: 10);
      expect(records, hasLength(1));
      final record = records.first;
      final files = record.files;
      expect(files, hasLength(1));
      expect(files.first.mediaId, mediaId);
      expect(files.first.filename, '$postId.mp4');
      expect(files.first.relativePath, 'Movies/EasySave');
      expect(files.first.md5, 'md5-$postId');
      expect(files.first.size, 4096000);

      GalleryLocatorService.instance.hasAccessForTesting = true;
      GalleryLocatorService.instance.assetByIdForTesting = (id) async {
        if (id == mediaId) {
          return AssetEntity(
            id: mediaId,
            typeInt: AssetType.video.index,
            width: 1080,
            height: 1920,
            title: '$postId.mp4',
            relativePath: 'Movies/EasySave',
          );
        }
        return null;
      };

      final post = ParsedPost(
        platform: 'douyin',
        id: postId,
        url: 'https://www.douyin.com/video/$postId',
        title: 'Cross Engine Video $postId',
        author: PostAuthor(name: 'Tester', id: 'u1'),
        items: [MediaItem(type: 'video', url: 'https://example.com/$postId.mp4')],
      );

      final result = await savedBrowserItems(
        record: record,
        files: files,
        post: post,
      );
      expect(result.items, hasLength(1));
      expect(result.items.first.missing, isFalse);
      expect(result.items.first.asset?.id, mediaId);

      final logs = DevLog.recentLines(100).join('\n');
      expect(
        logs,
        contains('[HIST] viewer_locate post=$postId by=mediaId result=ok'),
      );
    }

    test('event trigger: background initiates, main settles & locates immediately',
        () async {
      const batchId = 'background-p04e-evt-0';
      const postId = '7500001';
      const mediaId = 'media-evt-1';
      final batch = _makeCrossEngineBatch(batchId, postId);
      await seedBackgroundBatch(batch);

      await DownloadManager.instance.init();
      await DownloadManager.instance.reconcileFutureForTesting;
      fakeClient.controller.add(
        TransferCompletedEvent(
          jobId: 'xfer_${batchId}_0',
          mediaId: mediaId,
          title: '$postId.mp4',
          relativePath: 'Movies/EasySave',
          md5: 'md5-$postId',
          fileSize: 4096000,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 120));

      await verifyImmediateLocate(postId, mediaId);
    });

    test('snapshot trigger: background initiates, main settles & locates immediately',
        () async {
      const batchId = 'background-p04e-snap-0';
      const postId = '7500002';
      const mediaId = 'media-snap-2';
      final batch = _makeCrossEngineBatch(batchId, postId);
      await seedBackgroundBatch(batch);
      await DownloadManager.instance.init();
      await DownloadManager.instance.reconcileFutureForTesting;

      fakeClient.snapshotToReturn = [
        TransferJobSnapshot(
          jobId: 'xfer_${batchId}_0',
          direction: 'download',
          state: 'done',
          retryCount: 0,
          batchId: batchId,
          category: 'large_file',
          createdAt: 1000,
          updatedAt: 2000,
          bytesRead: 4096000,
          totalBytes: 4096000,
          mediaId: mediaId,
          title: '$postId.mp4',
          relativePath: 'Movies/EasySave',
          md5: 'md5-$postId',
          fileSize: 4096000,
          historyPending: true,
        ),
      ];

      await DownloadManager.instance.syncTransferBatchesFromSnapshotForTesting();
      await verifyImmediateLocate(postId, mediaId);
    });

    test(
        'startup_pending trigger: background initiates, main settles & locates immediately',
        () async {
      const batchId = 'background-p04e-pending-0';
      const postId = '7500003';
      const mediaId = 'media-pending-3';
      final batch = _makeCrossEngineBatch(batchId, postId);
      await seedBackgroundBatch(batch);

      fakeClient.pendingHistoryToReturn = [
        TransferJobSnapshot(
          jobId: 'xfer_${batchId}_0',
          direction: 'download',
          state: 'done',
          retryCount: 0,
          batchId: batchId,
          category: 'large_file',
          createdAt: 1000,
          updatedAt: 2000,
          bytesRead: 4096000,
          totalBytes: 4096000,
          mediaId: mediaId,
          title: '$postId.mp4',
          relativePath: 'Movies/EasySave',
          md5: 'md5-$postId',
          fileSize: 4096000,
          historyPending: true,
        ),
      ];

      await DownloadManager.instance.reconcileTransferHistoryPending(db: testDb);
      await verifyImmediateLocate(postId, mediaId);
    });
  });

  group('P0-4e unified overall progress & monotonicity', () {
    test('matches shared spec/batch_progress_vectors.json', () async {
      final candidates = [
        File('spec/batch_progress_vectors.json'),
        File('../spec/batch_progress_vectors.json'),
      ];
      final file = candidates.firstWhere((f) => f.existsSync());
      final decoded = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final vectors = decoded['vectors'] as List<dynamic>;
      expect(vectors, isNotEmpty);

      for (final raw in vectors) {
        final v = raw as Map<String, dynamic>;
        final name = v['name'] as String;
        final totalCount = v['batchTotalCount'] as int;
        final rawJobs = v['jobs'] as List<dynamic>;
        final jobs = <DownloadJob>[];
        for (var i = 0; i < rawJobs.length; i++) {
          final jm = rawJobs[i] as Map<String, dynamic>;
          final st = jm['state'] as String;
          jobs.add(
            DownloadJob(
              key: '$name-$i',
              label: 'image',
              itemIndex: i,
              isImage: true,
              urls: ['https://example.com/$i.jpg'],
              filename: '$i.jpg',
            )
              ..state = switch (st) {
                'done' => JobState.done,
                'running' => JobState.active,
                'failed' => JobState.failed,
                _ => JobState.queued,
              }
              ..usesNewTransferPipeline = true
              ..transferState = st
              ..bytesRead = jm['bytesRead'] as int
              ..expectedBytes = jm['totalBytes'] as int,
          );
        }
        final prev = (v['previousOverallProgress'] as num).toDouble();
        final rawOverall = DownloadBatch.computeTransferBatchOverallProgress(
          jobs,
          totalCount: totalCount,
        );
        final monotonicOverall = rawOverall > prev ? rawOverall : prev;
        final expected = (v['expectedOverallProgress'] as num).toDouble();
        expect(
          monotonicOverall,
          closeTo(expected, 0.001),
          reason: 'Vector $name mismatch',
        );
      }
    });

    test(
        'batch.progress is monotonic across sequential enqueue, concurrent completion, and candidate retry',
        () {
      final j1 = DownloadJob(
        key: 'm1',
        label: 'image',
        itemIndex: 0,
        isImage: true,
        urls: ['https://example.com/1a.jpg', 'https://example.com/1b.jpg'],
        filename: '1.jpg',
      )
        ..state = JobState.active
        ..usesNewTransferPipeline = true
        ..transferState = 'running'
        ..bytesRead = 600
        ..expectedBytes = 1000;
      final j2 = DownloadJob(
        key: 'm2',
        label: 'image',
        itemIndex: 1,
        isImage: true,
        urls: ['https://example.com/2.jpg'],
        filename: '2.jpg',
      )
        ..state = JobState.queued
        ..usesNewTransferPipeline = true
        ..transferState = 'queued';
      final j3 = DownloadJob(
        key: 'm3',
        label: 'image',
        itemIndex: 2,
        isImage: true,
        urls: ['https://example.com/3.jpg'],
        filename: '3.jpg',
      )
        ..state = JobState.queued
        ..usesNewTransferPipeline = true
        ..transferState = 'queued';
      final batch = DownloadBatch(
        batchId: 'main-mono-0',
        album: 'EasySave',
        postUrl: 'https://example.com/p/1',
        platform: 'x',
        postId: '1',
        pipeline: DownloadBatch.pipelineTransfer,
        jobs: [j1, j2, j3],
      );

      final p0 = batch.progress; // (0.6 + 0 + 0) / 3 = 0.2
      expect(p0, closeTo(0.2, 0.001));

      // Candidate retry resets j1 bytesRead to 0 while j2 starts at 300/1000.
      // Overall raw is 0.1, but batch.progress must remain >= p0 (0.2).
      j1
        ..bytesRead = 0
        ..transferState = 'running';
      j2
        ..state = JobState.active
        ..transferState = 'running'
        ..bytesRead = 300
        ..expectedBytes = 1000;
      final p1 = batch.progress;
      expect(p1, greaterThanOrEqualTo(p0));

      // j2 finishes (1.0) and j3 runs at 500/1000 (0.5) => (0 + 1 + 0.5) / 3 = 0.5
      j2
        ..state = JobState.done
        ..transferState = 'done'
        ..bytesRead = 1000;
      j3
        ..state = JobState.active
        ..transferState = 'running'
        ..bytesRead = 500
        ..expectedBytes = 1000;
      final p2 = batch.progress;
      expect(p2, closeTo(0.5, 0.001));

      final status = resolveDownloadStatus(batch: batch);
      expect(status.label, '下载中 50%');
    });
  });
}
