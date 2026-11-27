import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:easysave/core/dev_log.dart';
import 'package:easysave/core/models.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/settings.dart';
import 'package:easysave/services/transfer_client.dart';

class _ConfigurableTransferClient extends TransferClient {
  _ConfigurableTransferClient({super.methodChannel, super.enqueueTimeout});

  final StreamController<TransferEvent> controller =
      StreamController<TransferEvent>.broadcast();
  final List<Map<String, dynamic>> enqueued = [];
  List<TransferJobSnapshot> snapshots = const [];
  Object? enqueueError;
  Duration? enqueueDelay;

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
    if (enqueueDelay != null) {
      await Future<void>.delayed(enqueueDelay!);
    }
    if (enqueueError != null) {
      throw enqueueError!;
    }
    final id = jobId ?? '';
    enqueued.add({
      'jobId': id,
      'batchId': batchId,
      'url': url,
    });
    return id;
  }

  @override
  Future<List<TransferJobSnapshot>> snapshot() async => snapshots;

  @override
  Future<bool> claimHistoryWrite(String batchId) async => true;

  @override
  Future<bool> ackHistoryWritten(List<String> jobIds) async => true;

  @override
  Future<bool> claimMigration(String batchId) async => true;

  void dispose() {
    unawaited(controller.close());
  }
}

ParsedPost _samplePost(String postId) => ParsedPost(
  platform: 'xhs',
  id: postId,
  url: 'https://www.xiaohongshu.com/explore/$postId',
  author: PostAuthor(name: 'Tester'),
  title: 'Post $postId',
  items: [
    MediaItem(
      type: 'image',
      url: 'https://sns-img.xhscdn.com/test/$postId.jpg',
    ),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('gal'), (_) async => true);
    HistoryDb.resetInstanceForTesting();
    final db = await HistoryDb.instance(dbPath: ':memory:');
    HistoryDb.setInstanceForTesting(db);

    tempDir = await Directory.systemTemp.createTemp('p05e_test_');
    final dm = DownloadManager.instance;
    dm.resetReadyForTesting();
    dm.clearBatchesForTesting();
    dm.transfersDirForTesting = () async => Directory('${tempDir.path}/transfers');
    dm.settingsLoaderForTesting = () async => AppSettings();
    dm.downloaderStartForTesting = () async {};
    dm.clockForTesting = null;
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('gal'), null);
    final dm = DownloadManager.instance;
    dm.transferClientForTesting = null;
    dm.transfersDirForTesting = null;
    dm.settingsLoaderForTesting = null;
    dm.downloaderStartForTesting = null;
    dm.clockForTesting = null;
    dm.resetReadyForTesting();
    dm.clearBatchesForTesting();
    HistoryDb.resetInstanceForTesting();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('TransferClient.enqueue throws on null/empty result, MissingPluginException, and timeout', () async {
    const channel = MethodChannel('easysave/transfer_test_p05e');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    // 1. MissingPluginException (no handler registered)
    final clientNoHandler = TransferClient(methodChannel: channel);
    await expectLater(
      clientNoHandler.enqueue(jobId: 'j1', url: 'https://example.test/1.jpg'),
      throwsA(isA<MissingPluginException>()),
    );

    // 2. Empty jobId returned by native
    messenger.setMockMethodCallHandler(channel, (call) async => '');
    await expectLater(
      clientNoHandler.enqueue(jobId: 'j1', url: 'https://example.test/1.jpg'),
      throwsA(isA<StateError>()),
    );

    // 3. Timeout
    messenger.setMockMethodCallHandler(channel, (call) async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      return 'j1';
    });
    final shortTimeoutClient = TransferClient(
      methodChannel: channel,
      enqueueTimeout: const Duration(milliseconds: 30),
    );
    await expectLater(
      shortTimeoutClient.enqueue(jobId: 'j1', url: 'https://example.test/1.jpg'),
      throwsA(isA<TimeoutException>()),
    );

    messenger.setMockMethodCallHandler(channel, null);
  });

  test('new batch enqueue failure (exception / MissingPluginException / timeout) marks failed and never saved', () async {
    final dm = DownloadManager.instance;
    for (final err in <Object>[
      StateError('enqueue boom'),
      MissingPluginException('missing'),
      TimeoutException('timed out'),
    ]) {
      final client = _ConfigurableTransferClient()..enqueueError = err;
      dm.transferClientForTesting = client;
      final postId = 'fail-${err.runtimeType}';
      final batch = await dm.startBatch(
        _samplePost(postId),
        [0],
        album: 'EasySave',
        nameFor: (label, seq, ext) => '${postId}_$seq.$ext',
        requestGalleryAccess: false,
      );

      expect(batch.isTerminal, isTrue);
      expect(batch.jobs.single.state, JobState.failed);
      expect(batch.jobs.single.saved, isFalse);
      expect(batch.jobs.single.error, '启动失败，点重试');

      final db = await HistoryDb.instance();
      final record = await db.getByPostId(postId);
      expect(
        record?.files.where((f) => f.status == FileStatus.found) ?? const [],
        isEmpty,
      );
      expect(
        DevLog.recentLines(50).any((l) => l.contains('transfer_enqueue_failed')),
        isTrue,
      );
      client.dispose();
    }
  });

  test('snapshot missing: with .part reenqueues with part_bytes; without .part becomes interrupted and resume reenqueues from 0', () async {
    final dm = DownloadManager.instance;
    final client = _ConfigurableTransferClient()..snapshots = const [];
    dm.transferClientForTesting = client;

    final transfersDir = Directory('${tempDir.path}/transfers')..createSync(recursive: true);

    // Batch A: has .part (1234 bytes) -> reenqueue
    final jobA = DownloadJob(
      key: 'bA-0',
      label: '视频',
      filename: 'a.mp4',
      urls: ['https://sns-video-bd.xhscdn.com/a.mp4'],
      isImage: false,
      itemIndex: 1,
    )
      ..usesNewTransferPipeline = true
      ..transferJobId = 'xfer_bA-0'
      ..state = JobState.active
      ..transferState = 'running';
    final batchA = DownloadBatch(
      batchId: 'bA',
      album: 'EasySave',
      platform: 'xhs',
      postId: 'postA',
      postUrl: 'https://www.xiaohongshu.com/explore/postA',
      source: DownloadBatch.sourceMain,
      jobs: [jobA],
      pipeline: DownloadBatch.pipelineTransfer,
    );
    File('${transfersDir.path}/xfer_bA-0.part').writeAsBytesSync(List<int>.filled(1234, 7));

    // Batch B: no .part -> interrupted, resume reenqueues from 0
    final jobB = DownloadJob(
      key: 'bB-0',
      label: '图片',
      filename: 'b.jpg',
      urls: ['https://sns-img.xhscdn.com/b.jpg'],
      isImage: true,
      itemIndex: 1,
    )
      ..usesNewTransferPipeline = true
      ..transferJobId = 'xfer_bB-0'
      ..state = JobState.active
      ..transferState = 'running';
    final batchB = DownloadBatch(
      batchId: 'bB',
      album: 'EasySave',
      platform: 'xhs',
      postId: 'postB',
      postUrl: 'https://www.xiaohongshu.com/explore/postB',
      source: DownloadBatch.sourceMain,
      jobs: [jobB],
      pipeline: DownloadBatch.pipelineTransfer,
    );

    SharedPreferences.setMockInitialValues({
      'easysave_batches': ['bA', 'bB'],
      'easysave_batch_bA': jsonEncode(batchA.toJson()),
      'easysave_batch_bB': jsonEncode(batchB.toJson()),
    });
    await dm.reconcileForTesting();

    await dm.syncTransferBatchesFromSnapshotForTesting();

    final liveBatchA = dm.unfinishedBatches.firstWhere((b) => b.batchId == 'bA');
    final liveJobA = liveBatchA.jobs.single;
    expect(liveJobA.state, JobState.queued);
    expect(liveJobA.bytesRead, 1234);
    expect(client.enqueued.any((e) => e['jobId'] == 'xfer_bA-0'), isTrue);

    final liveBatchB = dm.unfinishedBatches.firstWhere((b) => b.batchId == 'bB');
    final liveJobB = liveBatchB.jobs.single;
    expect(liveJobB.state, JobState.paused);
    expect(liveJobB.userPaused, isFalse);
    expect(liveJobB.transferState, 'interrupted');
    expect(liveJobB.error, '已中断，点继续');
    expect(liveBatchB.historyWritten, isFalse);

    // User taps resume on interrupted batch B -> reenqueues from 0
    await dm.resumeBatch(liveBatchB);
    expect(liveJobB.state, JobState.queued);
    expect(liveJobB.bytesRead, 0);
    expect(client.enqueued.any((e) => e['jobId'] == 'xfer_bB-0'), isTrue);

    client.dispose();
  });

  test('writeBatchHistory rejects saved transfer job without mediaId and logs history_write_rejected_no_media', () async {
    final job = DownloadJob(
      key: 'no-media-0',
      label: '图片',
      filename: 'missing.jpg',
      urls: ['https://sns-img.xhscdn.com/missing.jpg'],
      isImage: true,
      itemIndex: 1,
    )
      ..usesNewTransferPipeline = true
      ..transferJobId = 'xfer_no-media-0'
      ..state = JobState.done
      ..saved = true
      ..mediaId = null;

    final batch = DownloadBatch(
      batchId: 'b-no-media',
      album: 'EasySave',
      platform: 'xhs',
      postId: 'post-no-media',
      postUrl: 'https://www.xiaohongshu.com/explore/post-no-media',
      source: DownloadBatch.sourceMain,
      jobs: [job],
      pipeline: DownloadBatch.pipelineTransfer,
    );

    final db = await HistoryDb.instance();
    await writeBatchHistory(db, batch, recovered: false);

    final record = await db.getByPostId('post-no-media', platform: 'xhs');
    expect(record, isNotNull);
    expect(record!.files.where((f) => f.status == FileStatus.found), isEmpty);
    expect(record.downloadError, isNotNull);
    expect(
      DevLog.recentLines(50).any((l) => l.contains('history_write_rejected_no_media')),
      isTrue,
    );
  });

  test('orphan .part and .meta older than 7 days without Store task or batch reference are cleaned', () async {
    final dm = DownloadManager.instance;
    final transfersDir = Directory('${tempDir.path}/transfers')..createSync(recursive: true);

    final now = DateTime(2026, 11, 27, 12, 0);
    final oldTime = now.subtract(const Duration(days: 8));
    final freshTime = now.subtract(const Duration(days: 2));

    // Orphan > 7 days (.part + .meta) -> should be deleted
    final orphanPart = File('${transfersDir.path}/orphan_old.part')
      ..writeAsBytesSync(List<int>.filled(500, 1))
      ..setLastModifiedSync(oldTime);
    final orphanMeta = File('${transfersDir.path}/orphan_old.meta')
      ..writeAsStringSync('{}')
      ..setLastModifiedSync(oldTime);

    // Recent orphan <= 7 days -> should be kept
    final recentPart = File('${transfersDir.path}/orphan_fresh.part')
      ..writeAsBytesSync(List<int>.filled(300, 2))
      ..setLastModifiedSync(freshTime);

    // Store-active > 7 days -> should be kept
    final storeActivePart = File('${transfersDir.path}/store_active.part')
      ..writeAsBytesSync(List<int>.filled(400, 3))
      ..setLastModifiedSync(oldTime);

    // Batch-referenced > 7 days -> should be kept
    final batchRefPart = File('${transfersDir.path}/batch_ref.part')
      ..writeAsBytesSync(List<int>.filled(600, 4))
      ..setLastModifiedSync(oldTime);

    final client = _ConfigurableTransferClient()
      ..snapshots = [
        const TransferJobSnapshot(
          jobId: 'store_active',
          direction: 'download',
          category: 'large_file',
          state: 'paused',
          bytesRead: 400,
          totalBytes: 1000,
          retryCount: 0,
          createdAt: 0,
          updatedAt: 0,
        ),
      ];
    dm.transferClientForTesting = client;

    final activeJob = DownloadJob(
      key: 'ref-0',
      label: '视频',
      filename: 'ref.mp4',
      urls: ['https://sns-video-bd.xhscdn.com/ref.mp4'],
      isImage: false,
      itemIndex: 1,
    )
      ..usesNewTransferPipeline = true
      ..transferJobId = 'batch_ref'
      ..state = JobState.paused;
    final activeBatch = DownloadBatch(
      batchId: 'b-ref',
      album: 'EasySave',
      platform: 'xhs',
      postId: 'post-ref',
      postUrl: 'https://www.xiaohongshu.com/explore/post-ref',
      source: DownloadBatch.sourceMain,
      jobs: [activeJob],
      pipeline: DownloadBatch.pipelineTransfer,
    );
    SharedPreferences.setMockInitialValues({
      'easysave_batches': ['b-ref'],
      'easysave_batch_b-ref': jsonEncode(activeBatch.toJson()),
    });
    dm.clockForTesting = () => now;
    await dm.reconcileForTesting();

    expect(orphanPart.existsSync(), isFalse);
    expect(orphanMeta.existsSync(), isFalse);
    expect(recentPart.existsSync(), isTrue);
    expect(storeActivePart.existsSync(), isTrue);
    expect(batchRefPart.existsSync(), isTrue);
    expect(
      DevLog.recentLines(50).any(
        (l) => l.contains('transfer_orphan_cleaned count=2'),
      ),
      isTrue,
    );

    client.dispose();
  });
}
