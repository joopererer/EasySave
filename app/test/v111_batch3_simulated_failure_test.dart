// Copyright 2026 EasySave. All rights reserved.
// v1.11 batch 3: the simulated failure must be a *final* failure.
//
// Build 50 device report: `simulated_failure=1` landed on the **second** file of
// the batch (`item failed index=2 reason=CONTENT attempt=1/20`), and the file
// was downloaded again afterwards, so the user saw everything succeed and no
// failure state to inspect.
//
// Now the switch fails the **first file of the plan**, once, and that failure is
// final: nothing re-downloads the file behind the user's back, the reason token
// is `SIMULATED` (never `CONTENT`), and a manual retry downloads normally.

import 'dart:io';

import 'package:easysave/core/dev_log.dart';
import 'package:easysave/core/models.dart';
import 'package:easysave/services/dev_download_failure.dart';
import 'package:easysave/services/download_claims.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/media_header_service.dart';
import 'package:easysave/services/network_status.dart';
import 'package:easysave/services/parse_service.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'test_helpers.dart';

const _postId = '2118566677374022101';

class _FakePaths extends PathProviderPlatform {
  _FakePaths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
}

DownloadBatch _batch(String id, {int files = 2, String? postUrl, String? postId}) => DownloadBatch(
  batchId: id,
  album: 'EasySave',
  postUrl: postUrl ?? 'https://www.xiaohongshu.com/explore/$_postId',
  platform: 'xhs',
  postId: postId ?? _postId,
  title: 'Post',
  itemsJson: '[{"type":"image","url":"https://sns-img.xhscdn.com/a.jpg"}]',
  postItemCount: files,
  jobs: [
    for (var i = 1; i <= files; i++)
      DownloadJob(
        key: '$id-$i',
        label: '图片 $i',
        filename: '${_postId}_$i.jpg',
        urls: ['https://sns-img.xhscdn.com/$i.jpg'],
        isImage: true,
        itemIndex: i,
      ),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final manager = DownloadManager.instance;
  final locator = GalleryLocatorService.instance;
  late HistoryDb db;
  late Directory temp;
  late Directory support;
  final logs = <String>[];

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    support = await Directory.systemTemp.createTemp('easysave_support_sim');
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
    DevDownloadFailure.resetForTesting();
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
    temp = await Directory.systemTemp.createTemp('easysave_simfinal');
    manager.tempRootForTesting = () async => temp;
    manager.historyWriterForTesting = (_, _, _) async {};
    logs.clear();
    debugPrint = (message, {wrapWidth}) => logs.add(message ?? '');
    manager.attachNetworkListenerForTesting();
  });

  tearDown(() async {
    debugPrint = debugPrintThrottled;
    for (final b in await manager.liveBatches()) {
      await DownloadClaims.release(b.batchId);
    }
    manager
      ..gallerySaveForTesting = null
      ..historyWriterForTesting = null
      ..enqueueForTesting = null
      ..reparseForTesting = null
      ..tempRootForTesting = null;
    MediaHeaderService.headerReader = null;
    manager.clearBatchesForTesting();
    locator.resetForTesting();
    HistoryDb.resetInstanceForTesting();
    DevDownloadFailure.resetForTesting();
    NetworkStatus.instance.resetForTesting();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<File> downloaded(String name) async {
    final file = File('${temp.path}/$name');
    await file.create(recursive: true);
    await file.writeAsBytes(Uint8List(1024));
    return file;
  }

  test('the switch fails the first file of the plan, not the first one that '
      'happens to finish', () async {
    final batch = _batch('plan-order', files: 2);
    manager.setBatchForTesting(batch);
    final saved = <int>[];
    manager.gallerySaveForTesting = (path, job) async {
      saved.add(job.itemIndex);
      return (
        mediaId: 'm${job.itemIndex}',
        title: job.filename,
        relativePath: 'Pictures/EasySave/',
      );
    };
    DevDownloadFailure.arm();

    // The second file reaches the import first, as it did on the device.
    await manager.importFileForTesting(
      batch,
      batch.jobs[1],
      (await downloaded('two.jpg')).path,
    );
    expect(batch.jobs[1].state, JobState.done,
        reason: 'the switch targets the plan order, not the finish order');
    expect(saved, [2]);
    expect(DevDownloadFailure.armed, isTrue, reason: 'still waiting for file 1');

    await manager.importFileForTesting(
      batch,
      batch.jobs[0],
      (await downloaded('one.jpg')).path,
    );
    final failed = batch.jobs[0];
    expect(failed.state, JobState.failed);
    expect(failed.error, '下载失败（模拟失败）');
    expect(failed.errorCode, simulatedFailureCode);
    expect(saved, [2], reason: 'nothing of the failed file reaches the album');
    expect(DevDownloadFailure.armed, isFalse);
  });

  test('the failure is reported as SIMULATED, never as CONTENT', () async {
    final batch = _batch('token', files: 1);
    manager.setBatchForTesting(batch);
    manager.gallerySaveForTesting = (path, job) async =>
        (mediaId: 'm', title: job.filename, relativePath: 'Pictures/EasySave/');
    DevDownloadFailure.arm();

    await manager.importFileForTesting(
      batch,
      batch.jobs.single,
      (await downloaded('only.jpg')).path,
    );

    final line = failedJobLogLine(batch, batch.jobs.single);
    expect(line, contains('reason=SIMULATED'));
    expect(line, isNot(contains('reason=CONTENT')));
    expect(shortFailureReason(batch.jobs.single), '模拟失败');
    expect(userFacingFailureReason(batch.jobs.single), '下载失败（模拟失败）',
        reason: 'the user reads the failure, not a doubled reason');
  });

  test('nothing re-enqueues a simulated failure on its own', () async {
    final batch = _batch('no-auto', files: 1);
    manager.setBatchForTesting(batch);
    manager.gallerySaveForTesting = (path, job) async =>
        (mediaId: 'm', title: job.filename, relativePath: 'Pictures/EasySave/');
    var enqueued = 0;
    manager.enqueueForTesting = (_, _) async => enqueued++;
    DevDownloadFailure.arm();

    final job = batch.jobs.single;
    await manager.importFileForTesting(batch, job, (await downloaded('a.jpg')).path);
    expect(job.state, JobState.failed);
    expect(isFinalFailure(job), isTrue);

    // The automatic path that re-drove the file on the device: the connection
    // read flips to online and every parked file is re-enqueued.
    job.state = JobState.waitingNetwork;
    NetworkStatus.instance.setOnlineForTesting(false);
    NetworkStatus.instance.setOnlineForTesting(true);
    await waitFor(
      () => job.state == JobState.failed,
      description: 'job returns to failed state after network reconnect',
    );

    expect(enqueued, 0, reason: 'a decided failure is never re-downloaded');
    expect(job.state, JobState.failed);
    expect(job.errorCode, simulatedFailureCode);
    expect(
      logs.join('\n'),
      isNot(contains('gallery import done')),
      reason: 'a late pass must not sneak the file into the album',
    );
  });

  test('a manual retry downloads the file normally', () async {
    final batch = _batch(
      'manual',
      files: 1,
      postUrl: 'https://www.xiaohongshu.com/explore/retry_post',
      postId: 'retry_post',
    );
    final job = batch.jobs.single
      ..urls = ['https://ci.xiaohongshu.com/expired.jpg'];
    manager.setBatchForTesting(batch);
    manager.gallerySaveForTesting = (path, job) async =>
        (mediaId: 'm', title: job.filename, relativePath: 'Pictures/EasySave/');
    final fresh = ParsedPost(
      platform: 'xhs',
      id: 'retry_post',
      url: 'https://www.xiaohongshu.com/explore/retry_post',
      author: PostAuthor(),
      items: [MediaItem(type: 'image', url: 'https://ci.xiaohongshu.com/fresh.jpg')],
    );
    manager.reparseForTesting = (_) async => ParseOutcome(data: fresh, rawImages: const []);
    var enqueued = 0;
    manager.enqueueForTesting = (_, _) async => enqueued++;
    DevDownloadFailure.arm();

    await manager.importFileForTesting(batch, job, (await downloaded('a.jpg')).path);
    expect(job.state, JobState.failed);

    await manager.retryJob(batch, job);

    expect(enqueued, 1, reason: 'the manual retry enqueues the fresh link');
    expect(job.errorCode, isNull, reason: 'the simulated code is cleared');
    expect(job.state, isNot(JobState.failed));
    expect(job.urls, ['https://ci.xiaohongshu.com/fresh.jpg']);
    expect(DevDownloadFailure.armed, isFalse, reason: 'still a one-shot switch');
  });
}
