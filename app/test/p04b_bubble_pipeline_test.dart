import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:easysave/core/models.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/media_request_policy.dart';
import 'package:easysave/services/parse_service.dart';
import 'package:easysave/services/transfer_client.dart';

class _BubbleFakeTransferClient extends TransferClient {
  final StreamController<TransferEvent> controller =
      StreamController<TransferEvent>.broadcast();
  final List<Map<String, dynamic>> enqueued = [];
  final List<Map<String, dynamic>> updatedUrls = [];
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
    enqueued.add({
      'jobId': jobId,
      'batchId': batchId,
      'cookie': cookie,
      'allowedCookieDomains': allowedCookieDomains,
      'policyKey': policyKey,
    });
    return jobId ?? '';
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
    updatedUrls.add({'jobId': jobId, 'url': url, 'cookie': cookie});
    return true;
  }

  void dispose() {
    unawaited(controller.close());
  }
}

ParsedPost _makePost(String id, {String platform = 'x'}) {
  return ParsedPost(
    platform: platform,
    id: id,
    url: platform == 'tiktok'
        ? 'https://www.tiktok.com/@u/video/$id'
        : 'https://x.com/u/status/$id',
    title: 'Post $id',
    author: PostAuthor(name: 'Tester', id: 'u1'),
    items: [
      MediaItem(
        type: 'video',
        url: platform == 'tiktok'
            ? 'https://v16.tiktok.com/video_$id.mp4'
            : 'https://video.twimg.com/ext_tw_video/$id/pu/vid/v.mp4',
      ),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late HistoryDb testDb;
  late _BubbleFakeTransferClient fakeClient;
  late String prevOwner;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    prevOwner = DownloadManager.owner;
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('p04b_bubble_');
    HistoryDb.resetInstanceForTesting();
    testDb = await HistoryDb.instance(dbPath: '${tempDir.path}/history.db');
    HistoryDb.setInstanceForTesting(testDb);
    fakeClient = _BubbleFakeTransferClient();

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
    DownloadManager.owner = prevOwner;
    final dm = DownloadManager.instance;
    dm.prepareStartForTesting = null;
    dm.transferClientForTesting = null;
    dm.useNewTransferPipelineForTesting = null;
    dm.tempRootForTesting = null;
    dm.historyWriterForTesting = null;
    dm.enqueueForTesting = null;
    dm.reparseForTesting = null;
    MediaRequestPolicy.defaultCookieReaderForTesting = null;
    fakeClient.dispose();
    HistoryDb.resetInstanceForTesting();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  test('floating bubble (sourceBackground) routes to TransferService with 0 legacy calls', () async {
    DownloadManager.owner = DownloadBatch.sourceBackground;
    final dm = DownloadManager.instance;
    var legacyCalls = 0;
    dm.enqueueForTesting = (b, j) async => legacyCalls++;

    final post = _makePost('bg_1');
    final batch = await dm.startBatch(
      post,
      const [0],
      album: 'EasySave',
      nameFor: (_, s, _) => '${post.id}_$s',
      requestGalleryAccess: false,
    );

    expect(batch.source, DownloadBatch.sourceBackground);
    expect(batch.pipeline, DownloadBatch.pipelineTransfer);
    expect(batch.usesNewTransferPipeline, isTrue);
    expect(fakeClient.enqueued, hasLength(1));
    expect(legacyCalls, 0);
  });

  test('two engines receiving completion write history only once via claimHistoryWrite', () async {
    DownloadManager.owner = DownloadBatch.sourceBackground;
    final dm = DownloadManager.instance;
    final post = _makePost('claim_once_1');
    final batch = await dm.startBatch(
      post,
      const [0],
      album: 'EasySave',
      nameFor: (_, s, _) => '${post.id}_$s',
      requestGalleryAccess: false,
    );
    final job = batch.jobs.single;
    job
      ..saved = true
      ..state = JobState.done
      ..mediaId = '7001'
      ..savedTitle = '${post.id}_1.mp4'
      ..relativePath = 'Pictures/EasySave/'
      ..fileBytes = 1024;

    var writeCalls = 0;
    dm.historyWriterForTesting = (db, b, recovered) async {
      writeCalls++;
      await writeBatchHistory(db, b, recovered: recovered);
    };

    // First engine claims and writes
    await dm.afterTerminalForTesting(batch, fromTransferPipeline: true);
    expect(writeCalls, 1);

    // Second engine (simulating main UI receiving the same event) is blocked by claimHistoryWrite
    final batchClone = DownloadBatch.fromJson(batch.toJson())
      ..historyWritten = false
      ..settledBy = null;
    final claimed2 = await fakeClient.claimHistoryWrite(batchClone.batchId);
    expect(claimed2, isFalse);
    expect(writeCalls, 1);
  });

  test('claim timeout releases after 60s so another engine backfills once', () async {
    DownloadManager.owner = DownloadBatch.sourceBackground;
    final dm = DownloadManager.instance;
    final post = _makePost('claim_timeout_1');
    final batch = await dm.startBatch(
      post,
      const [0],
      album: 'EasySave',
      nameFor: (_, s, _) => '${post.id}_$s',
      requestGalleryAccess: false,
    );
    final jobId = batch.jobs.single.transferJobId!;

    // Engine 1 claims at t=1000000 and crashes before writing history
    expect(await fakeClient.claimHistoryWrite(batch.batchId), isTrue);

    // Within 60s, Engine 2 cannot claim
    fakeClient.nowMs = 1030000;
    expect(await fakeClient.claimHistoryWrite(batch.batchId), isFalse);

    // After 60s timeout, Engine 2 reconciles pending history and writes once
    fakeClient.nowMs = 1060000;
    fakeClient.pendingHistoryToReturn = [
      TransferJobSnapshot(
        jobId: jobId,
        direction: 'download',
        category: 'large_file',
        batchId: batch.batchId,
        state: 'done',
        retryCount: 0,
        createdAt: 1,
        updatedAt: 2,
        mediaId: '7002',
        title: '${post.id}_1.mp4',
        relativePath: 'Pictures/EasySave/',
        md5: 'deadbeef',
        fileSize: 2048,
        historyPending: true,
      ),
    ];

    await dm.reconcileTransferHistoryPending(db: testDb);
    final rec = await testDb.getByPostId(post.id);
    expect(rec, isNotNull);
    expect(rec!.files, hasLength(1));
    expect(fakeClient.acked.expand((e) => e), contains(jobId));
  });

  test('engine recreated after destroy restores live progress from TransferClient snapshot', () async {
    DownloadManager.owner = DownloadBatch.sourceBackground;
    final dm = DownloadManager.instance;
    final post = _makePost('restore_prog_1');
    final batch = await dm.startBatch(
      post,
      const [0],
      album: 'EasySave',
      nameFor: (_, s, _) => '${post.id}_$s',
      requestGalleryAccess: false,
    );
    final jobId = batch.jobs.single.transferJobId!;

    // Service advances to 60% while engine was destroyed
    fakeClient.snapshotToReturn = [
      TransferJobSnapshot(
        jobId: jobId,
        direction: 'download',
        category: 'large_file',
        batchId: batch.batchId,
        state: 'running',
        retryCount: 0,
        createdAt: 1,
        updatedAt: 2,
        bytesRead: 600,
        totalBytes: 1000,
      ),
    ];

    await dm.syncTransferBatchesFromSnapshotForTesting();
    expect(batch.jobs.single.state, JobState.active);
    expect(batch.jobs.single.progress, closeTo(0.6, 0.001));
  });

  test('cookie-requiring job triggers reresolve_required and updateUrlAndResume', () async {
    MediaRequestPolicy.defaultCookieReaderForTesting = (_) async => 'sessionid=fresh_cookie_123';
    DownloadManager.owner = DownloadBatch.sourceBackground;
    final dm = DownloadManager.instance;
    final post = _makePost('tt_cookie_1', platform: 'tiktok');

    dm.reparseForTesting = (url) async => ParseOutcome(
      rawImages: const [],
      data: ParsedPost(
        platform: 'tiktok',
        id: 'tt_cookie_1',
        url: url,
        title: 'Fresh TT',
        author: PostAuthor(name: 'Tester', id: 'u1'),
        items: [
          MediaItem(
            type: 'video',
            url: 'https://v16.tiktok.com/fresh_video.mp4',
          ),
        ],
      ),
    );

    final batch = await dm.startBatch(
      post,
      const [0],
      album: 'EasySave',
      nameFor: (_, s, _) => '${post.id}_$s',
      requestGalleryAccess: false,
    );
    final jobId = batch.jobs.single.transferJobId!;

    fakeClient.controller.add(TransferReresolveRequiredEvent(jobId: jobId));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(fakeClient.updatedUrls, hasLength(1));
    expect(fakeClient.updatedUrls.single['jobId'], jobId);
    expect(
      fakeClient.updatedUrls.single['url'],
      'https://v16.tiktok.com/fresh_video.mp4',
    );
  });
}
