import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:easysave/core/dev_log.dart';
import 'package:easysave/core/models.dart';
import 'package:easysave/pages/download_queue_page.dart';
import 'package:easysave/pages/parse_page.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/download_status_display.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/parse_service.dart';
import 'package:easysave/services/transfer_client.dart';
import 'package:easysave/widgets/download_sheet.dart';
import 'package:easysave/widgets/history_cards.dart';

class _P04cFakeTransferClient extends TransferClient {
  final StreamController<TransferEvent> controller =
      StreamController<TransferEvent>.broadcast();
  final List<String> resumed = [];
  final List<String> retried = [];
  final List<List<String>> acked = [];
  List<TransferJobSnapshot> snapshotToReturn = [];
  List<TransferJobSnapshot> pendingHistoryToReturn = [];
  final Map<String, int> _claims = {};
  int nowMs = 1000000;

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
    return jobId ?? '';
  }

  @override
  Future<bool> pause(String jobId) async => true;

  @override
  Future<bool> resume(String jobId) async {
    resumed.add(jobId);
    return true;
  }

  @override
  Future<bool> retry(String jobId) async {
    retried.add(jobId);
    return true;
  }

  @override
  Future<bool> claimHistoryWrite(String batchId) async {
    final prev = _claims[batchId];
    if (prev != null && (nowMs - prev) < 60000) {
      return false;
    }
    _claims[batchId] = nowMs;
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

ParsedPost _makePost(String id) {
  return ParsedPost(
    platform: 'xiaohongshu',
    id: id,
    url: 'https://www.xiaohongshu.com/explore/$id',
    title: 'Post $id',
    author: PostAuthor(name: 'Tester', id: 'u1'),
    items: [
      MediaItem(
        type: 'video',
        url: 'https://sns-video-bd.xhscdn.com/video_$id.mp4',
      ),
    ],
  );
}

DownloadBatch _makeTransferBatch({
  required String batchId,
  required String source,
  required String postId,
  String transferState = 'running',
  JobState jobState = JobState.active,
  int? expectedBytes,
  int bytesRead = 0,
  double progress = 0.0,
}) {
  final job = DownloadJob(
    key: '${postId}_1',
    label: 'video',
    filename: '${postId}_1.mp4',
    urls: ['https://sns-video-bd.xhscdn.com/video_$postId.mp4'],
    isImage: false,
    itemIndex: 1,
  )
    ..usesNewTransferPipeline = true
    ..transferJobId = 'xfer_${postId}_1'
    ..transferState = transferState
    ..state = jobState
    ..expectedBytes = expectedBytes
    ..bytesRead = bytesRead
    ..progress = progress;
  return DownloadBatch(
    batchId: batchId,
    album: 'EasySave',
    postUrl: 'https://www.xiaohongshu.com/explore/$postId',
    platform: 'xiaohongshu',
    postId: postId,
    title: 'Post $postId',
    source: source,
    pipeline: DownloadBatch.pipelineTransfer,
    jobs: [job],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late HistoryDb testDb;
  late _P04cFakeTransferClient fakeClient;
  late String prevOwner;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    prevOwner = DownloadManager.owner;
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('p04c_test_');
    HistoryDb.resetInstanceForTesting();
    testDb = await HistoryDb.instance(dbPath: '${tempDir.path}/history.db');
    HistoryDb.setInstanceForTesting(testDb);
    fakeClient = _P04cFakeTransferClient();

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
    dm.downloaderStartForTesting = null;
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

  group('Part 1: transfer batch removes ownership/adopt/takeover rules', () {
    test(
      'bubble batch finished while engines dead -> main engine settles once, bubble second start does not duplicate, 0 legacy calls',
      () async {
        DevLog.resetRecentForTesting();

        var legacyCalls = 0;
        final dm = DownloadManager.instance;
        dm.enqueueForTesting = (_, _) async {
          legacyCalls++;
        };
        dm.resumeForTesting = (_) async {
          legacyCalls++;
          return true;
        };
        dm.pauseForTesting = (_) async {
          legacyCalls++;
          return true;
        };
        dm.cancelTaskForTesting = (_) async {
          legacyCalls++;
        };

        var historyWriteCount = 0;
        dm.historyWriterForTesting = (db, batch, recovered) async {
          historyWriteCount++;
          await writeBatchHistory(db, batch, recovered: recovered);
        };

        // Simulate bubble engine having persisted a transfer batch before dying
        const batchId = 'background-1795623134582990-0';
        final bubbleBatch = _makeTransferBatch(
          batchId: batchId,
          source: DownloadBatch.sourceBackground,
          postId: '2990',
          transferState: 'running',
          jobState: JobState.active,
        );
        final prefs = await SharedPreferences.getInstance();
        await prefs.setStringList('easysave_batches', [batchId]);
        await prefs.setString(
          'easysave_batch_$batchId',
          jsonEncode(bubbleBatch.toJson()),
        );

        // TransferService completed the job while both engines were dead
        final completedSnap = TransferJobSnapshot(
          jobId: 'xfer_2990_1',
          direction: 'download',
          state: 'done',
          retryCount: 0,
          batchId: batchId,
          category: 'video',
          createdAt: 1000,
          updatedAt: 2000,
          bytesRead: 1024000,
          totalBytes: 1024000,
          mediaId: 'media-2990',
          title: '2990_1.mp4',
          relativePath: 'Movies/EasySave',
          md5: 'deadbeef',
          fileSize: 1024000,
          historyPending: true,
        );
        fakeClient.snapshotToReturn = [completedSnap];
        fakeClient.pendingHistoryToReturn = [completedSnap];

        // Start only main UI engine
        DownloadManager.owner = DownloadBatch.sourceMain;
        await dm.reconcile();
        await dm.reconcileFutureForTesting;
        for (var i = 0; i < 40 && fakeClient.acked.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        await dm.reconcileTransferHistoryPending(db: testDb);

        expect(historyWriteCount, 1);
        expect(legacyCalls, 0);
        final logs = DevLog.recentLines(200);
        expect(
          logs.any((l) => l.contains('skip foreign batch')),
          isFalse,
        );
        expect(
          logs.any((l) => l.contains('reason=force_adopt')),
          isFalse,
        );
        expect(
          logs.any((l) => l.contains('legacy_call_blocked')),
          isFalse,
        );
        expect(
          logs.any(
            (l) =>
                l.contains('[V16DL]') &&
                l.contains(
                  'transfer_settle batch=$batchId trigger=startup_pending engine=main claim=won',
                ),
          ),
          isTrue,
        );
        expect(fakeClient.acked.expand((e) => e), contains('xfer_2990_1'));

        final batches = await dm.liveBatches();
        final settled = batches.firstWhere((b) => b.batchId == batchId);
        expect(settled.isTerminal, isTrue);
        expect(settled.failedCount, 0);
        expect(resolveDownloadStatus(batch: settled).label, '全部完成 ✓');

        // Also simulate bubble engine starting and attempting to settle the same batch
        DownloadManager.owner = DownloadBatch.sourceBackground;
        dm.resetInitForTesting();
        dm.clearBatchesForTesting();
        await dm.reconcile();
        await dm.reconcileTransferHistoryPending(db: testDb);
        expect(historyWriteCount, 1);
        expect(legacyCalls, 0);
      },
    );

    test(
      'resume/retry/restart on transfer batch only calls TransferClient and settles already-done snapshot without re-download',
      () async {
        DevLog.resetRecentForTesting();

        var legacyCalls = 0;
        final dm = DownloadManager.instance;
        dm.enqueueForTesting = (_, _) async {
          legacyCalls++;
        };
        dm.cancelTaskForTesting = (_) async {
          legacyCalls++;
        };

        DownloadManager.owner = DownloadBatch.sourceMain;
        final batch = _makeTransferBatch(
          batchId: 'background-restart-1',
          source: DownloadBatch.sourceBackground,
          postId: '3001',
          transferState: 'interrupted',
          jobState: JobState.paused,
        );

        // Snapshot shows job is actually already done in TransferService
        fakeClient.snapshotToReturn = [
          TransferJobSnapshot(
            jobId: 'xfer_3001_1',
            direction: 'download',
            state: 'done',
            retryCount: 0,
            batchId: batch.batchId,
            category: 'video',
            createdAt: 1000,
            updatedAt: 2000,
            bytesRead: 5000,
            totalBytes: 5000,
            mediaId: 'm-3001',
            title: '3001_1.mp4',
            relativePath: 'Movies/EasySave',
            md5: 'abc',
            fileSize: 5000,
            historyPending: true,
          ),
        ];

        await dm.forceAdopt(batch);
        await dm.restartBatch(batch);

        expect(legacyCalls, 0);
        expect(fakeClient.retried, isEmpty);
        expect(fakeClient.resumed, isEmpty);
        expect(batch.isTerminal, isTrue);
        expect(batch.historyWritten, isTrue);
        final logs = DevLog.recentLines(200);
        expect(logs.any((l) => l.contains('force_adopt')), isFalse);
        expect(logs.any((l) => l.contains('legacy_call_blocked')), isFalse);
      },
    );
  });

  group('Part 2: queue & status percentage display (transfer pipeline only)', () {
    test('resolveDownloadStatus computes byte-weighted batch percentage', () {
      final j1 = DownloadJob(
        key: 'k1',
        label: 'img',
        filename: '1.jpg',
        urls: ['https://example.com/1.jpg'],
        isImage: true,
        itemIndex: 1,
      )
        ..usesNewTransferPipeline = true
        ..transferState = 'done'
        ..state = JobState.done
        ..expectedBytes = 1000
        ..bytesRead = 1000
        ..progress = 1.0;
      final j2 = DownloadJob(
        key: 'k2',
        label: 'vid',
        filename: '2.mp4',
        urls: ['https://example.com/2.mp4'],
        isImage: false,
        itemIndex: 2,
      )
        ..usesNewTransferPipeline = true
        ..transferState = 'running'
        ..state = JobState.active
        ..expectedBytes = 9000
        ..bytesRead = 1000
        ..progress = 1000 / 9000;
      final batch = DownloadBatch(
        batchId: 'b-weighted',
        album: 'EasySave',
        postUrl: 'https://example.com/p',
        platform: 'xiaohongshu',
        postId: 'p',
        pipeline: DownloadBatch.pipelineTransfer,
        jobs: [j1, j2],
      );

      // Unified overall progress: (1 + 1000 / 9000) / 2 = 55.56% -> 56%
      final batchStatus = resolveDownloadStatus(batch: batch);
      expect(batchStatus.label, '下载中 56%');
      final jobStatus = resolveDownloadStatus(job: j2);
      expect(jobStatus.label, '下载中 11%');
    });

    testWidgets(
      'DownloadQueuePage, DownloadSheet, and DownloadingOverlay display percentage for transfer batch',
      (tester) async {
        final batch = _makeTransferBatch(
          batchId: 'main-pct-1',
          source: DownloadBatch.sourceMain,
          postId: 'pct1',
          transferState: 'running',
          jobState: JobState.active,
          expectedBytes: 1000,
          bytesRead: 420,
          progress: 0.42,
        );
        final prefs = await SharedPreferences.getInstance();
        await prefs.setStringList('easysave_batches', [batch.batchId]);
        await prefs.setString(
          'easysave_batch_${batch.batchId}',
          jsonEncode(batch.toJson()),
        );

        await tester.pumpWidget(
          const MaterialApp(home: DownloadQueuePage()),
        );
        await tester.pumpAndSettle();

        expect(find.textContaining('下载中 42% · 0/1 项'), findsOneWidget);

        // Expand batch tile to verify item row
        await tester.tap(find.text('Post pct1'));
        await tester.pumpAndSettle();
        expect(find.text('下载中 42%'), findsOneWidget);

        // DownloadSheet
        DownloadManager.instance.setBatchForTesting(batch);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: DownloadSheet(
                batchId: batch.batchId,
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.text('下载中 42% · 0/1 项'), findsOneWidget);
        expect(find.text('下载中 42%'), findsOneWidget);

        // DownloadingOverlay (History card)
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: DownloadingOverlay(
                progress: batch.progress,
                batch: batch,
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.text('下载中 42%'), findsOneWidget);
      },
    );
  });

  group('Part 3: ParseFlow 30s timeout, dedup release, and step logs', () {
    testWidgets(
      'hanging parse times out after 30s with prompt and releases dedup for retry',
      (tester) async {
        DevLog.resetRecentForTesting();

        var calls = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ParsePage(
                initializeServices: false,
              ),
            ),
          ),
        );

        final state = tester.state<ParsePageState>(find.byType(ParsePage));
        state.parsePostOutcomeForTesting = (
          url, {
          source = 'input',
          forceRefresh = false,
          onCacheHit,
          onStep,
        }) {
          calls++;
          if (calls == 1) {
            return Completer<ParseOutcome>().future;
          }
          onStep?.call('cache');
          return Future.value(
            ParseOutcome(data: _makePost('ok1'), rawImages: const []),
          );
        };

        await tester.enterText(
          find.byType(TextField),
          'https://www.xiaohongshu.com/explore/670f1a2b000000001e028b12',
        );
        await tester.tap(find.text('解析'));
        await tester.pump();

        expect(calls, 1);

        // Second tap while still running -> deduped
        unawaited(
          state.showExternalUrl(
            'https://www.xiaohongshu.com/explore/670f1a2b000000001e028b12',
          ),
        );
        await tester.pump();
        expect(calls, 1);
        expect(
          DevLog.recentLines(200)
              .any((l) => l.contains('[ParseFlow]') && l.contains('dedup=1')),
          isTrue,
        );

        // Advance 30s -> triggers timeout
        await tester.pump(const Duration(seconds: 30));
        await tester.pump();

        expect(find.text('解析超时，请重试'), findsOneWidget);
        expect(
          DevLog.recentLines(200).any(
            (l) => l.contains('[ParseFlow]') && l.contains('event=timeout'),
          ),
          isTrue,
        );

        // Tap again after timeout -> dedup released, starts a new parse
        await tester.tap(find.text('重试'));
        await tester.pump();
        expect(calls, 2);
      },
    );

    test(
      'two CachedPostParser instances parsing concurrently do not deadlock and release _running after timeout',
      () async {
        var fakeNow = DateTime(2026, 1, 1, 12, 0, 0);
        var hangCalls = 0;
        final parserA = CachedPostParser(
          parseTimeout: const Duration(seconds: 30),
          now: () => fakeNow,
          parseNetwork: (url, entry) async {
            if (url.contains('hang')) {
              hangCalls++;
              if (hangCalls == 1) {
                return Completer<ParseOutcome>().future;
              }
            }
            return ParseOutcome(data: _makePost('a1'), rawImages: const []);
          },
        );
        final parserB = CachedPostParser(
          parseTimeout: const Duration(seconds: 30),
          parseNetwork: (url, entry) async =>
              ParseOutcome(data: _makePost('b1'), rawImages: const []),
        );

        final res = await Future.wait([
          parserA.parse('https://www.xiaohongshu.com/explore/a1'),
          parserB.parse('https://www.xiaohongshu.com/explore/b1'),
        ]);
        expect(res[0].data.id, 'a1');
        expect(res[1].data.id, 'b1');

        // Start a hanging parse; within 30s a second call is deduped
        unawaited(
          parserA.parse('https://www.xiaohongshu.com/explore/hang'),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(hangCalls, 1);

        unawaited(
          parserA.parse('https://www.xiaohongshu.com/explore/hang'),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(hangCalls, 1);

        // Advance past 30s -> dedup entry evicted, new call starts fresh
        fakeNow = fakeNow.add(const Duration(seconds: 31));
        final retryOutcome = await parserA.parse(
          'https://www.xiaohongshu.com/explore/hang',
        );
        expect(hangCalls, 2);
        expect(retryOutcome.data.id, 'a1');
      },
    );
  });
}

