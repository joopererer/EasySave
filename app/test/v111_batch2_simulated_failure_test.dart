// Copyright 2026 EasySave. All rights reserved.
// v1.11 batch 2: the "下一次下载模拟失败" developer switch.
//
// The failure snapshot only exists after a real failure, so a real device can
// only test it by breaking something. The switch fails the first file of the
// next batch on purpose, once, through the normal failure path: same message
// shape, same snapshot, no album write, and a `simulated_failure=1` marker in
// the log so a snapshot taken from it cannot be mistaken for a defect.

import 'dart:io';
import 'dart:typed_data';

import 'package:easysave/core/dev_log.dart';
import 'package:easysave/services/dev_download_failure.dart';
import 'package:easysave/services/download_claims.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/media_header_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _postId = '2118566677374022101';

class _FakePaths extends PathProviderPlatform {
  _FakePaths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
}

DownloadBatch _batch(String id, {int files = 2}) => DownloadBatch(
  batchId: id,
  album: 'EasySave',
  postUrl: 'https://www.xiaohongshu.com/explore/$_postId',
  platform: 'xhs',
  postId: _postId,
  title: 'Post',
  itemsJson: '[{"type":"image","url":"https://sns-img.xhscdn.com/a.jpg"}]',
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
    support = await Directory.systemTemp.createTemp('easysave_support');
    PathProviderPlatform.instance = _FakePaths(support.path);
  });
  tearDownAll(() async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    if (await support.exists()) await support.delete(recursive: true);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    DevLog.resetRecentForTesting();
    DevDownloadFailure.resetForTesting();
    manager.clearBatchesForTesting();
    HistoryDb.resetInstanceForTesting();
    db = await HistoryDb.instance(dbPath: ':memory:');
    HistoryDb.setInstanceForTesting(db);
    await db.clear();
    locator.resetForTesting();
    locator.nativeIndexReaderForTesting =
        (_) async => {'permission': 'denied', 'items': []};
    MediaHeaderService.headerReader = (_, _) async => Uint8List(0);
    temp = await Directory.systemTemp.createTemp('easysave_simfail');
    manager.tempRootForTesting = () async => temp;
    logs.clear();
    debugPrint = (message, {wrapWidth}) => logs.add(message ?? '');
  });

  tearDown(() async {
    debugPrint = debugPrintThrottled;
    for (final b in await manager.liveBatches()) {
      await DownloadClaims.release(b.batchId);
    }
    manager
      ..gallerySaveForTesting = null
      ..historyWriterForTesting = null
      ..albumProvenanceForTesting = null
      ..mediaSizeForTesting = null
      ..tempRootForTesting = null;
    MediaHeaderService.headerReader = null;
    manager.clearBatchesForTesting();
    locator.resetForTesting();
    HistoryDb.resetInstanceForTesting();
    DevDownloadFailure.resetForTesting();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<File> downloaded(DownloadBatch batch, String name) async {
    final file = File('${temp.path}/$name');
    await file.create(recursive: true);
    await file.writeAsBytes(Uint8List(1024));
    return file;
  }

  group('the switch', () {
    test('is off until armed and goes off again after one use', () {
      expect(DevDownloadFailure.armed, isFalse);
      expect(DevDownloadFailure.take('batch-a', firstFile: true), isFalse);
      DevDownloadFailure.arm();
      expect(DevDownloadFailure.armed, isTrue);
      expect(DevDownloadFailure.take('batch-a', firstFile: true), isTrue);
      expect(DevDownloadFailure.armed, isFalse,
          reason: 'one shot, then it turns itself off');
      expect(DevDownloadFailure.take('batch-a', firstFile: true), isFalse);
    });

    test('only the next batch is affected, not another one', () {
      DevDownloadFailure.arm();
      expect(DevDownloadFailure.take('first-batch', firstFile: true), isTrue);
      DevDownloadFailure.arm();
      expect(DevDownloadFailure.take('batch-b', firstFile: true), isTrue);
      expect(DevDownloadFailure.take('batch-c', firstFile: true), isFalse);
    });

    test('a restart starts disarmed (in memory only)', () {
      DevDownloadFailure.arm();
      // A new process has no state at all; resetForTesting models that.
      DevDownloadFailure.resetForTesting();
      expect(DevDownloadFailure.armed, isFalse);
      expect(DevDownloadFailure.take('batch-a', firstFile: true), isFalse);
    });
  });

  test('the first file of the next batch fails before the album write and the '
      'rest of the batch is untouched', () async {
    final batch = _batch('simfail', files: 2);
    manager.setBatchForTesting(batch);
    manager.historyWriterForTesting = (_, _, _) async {};
    var saved = 0;
    manager.gallerySaveForTesting = (path, job) async {
      saved++;
      return (
        mediaId: '90${job.itemIndex}',
        title: job.filename,
        relativePath: 'Pictures/EasySave/',
      );
    };

    final first = await downloaded(batch, 'one.jpg');
    final second = await downloaded(batch, 'two.jpg');
    DevDownloadFailure.arm();

    await manager.importFileForTesting(batch, batch.jobs[0], first.path);
    final failed = batch.jobs[0];
    expect(failed.state, JobState.failed);
    expect(failed.error, '下载失败（模拟失败）');
    expect(failed.errorCode, simulatedFailureCode);
    expect(saved, 0, reason: 'nothing may reach the album');
    expect(DevDownloadFailure.armed, isFalse);
    expect(
      DevLog.recentLines(400).any(
        (line) =>
            line.contains('[V16DL]') && line.contains('simulated_failure=1'),
      ),
      isTrue,
      reason: 'the snapshot must be identifiable as simulated',
    );

    // The second file of the same batch downloads and imports normally.
    await manager.importFileForTesting(batch, batch.jobs[1], second.path);
    expect(batch.jobs[1].state, JobState.done);
    expect(saved, 1);
    expect(batch.jobs[1].mediaId, '902');
    expect(batch.failedCount, 1);
  });

  test('an unarmed build imports every file as before', () async {
    final batch = _batch('control', files: 1);
    manager.setBatchForTesting(batch);
    manager.historyWriterForTesting = (_, _, _) async {};
    var saved = 0;
    manager.gallerySaveForTesting = (path, job) async {
      saved++;
      return (mediaId: '99', title: job.filename, relativePath: 'Pictures/EasySave/');
    };
    final file = await downloaded(batch, 'only.jpg');

    await manager.importFileForTesting(batch, batch.jobs.single, file.path);
    expect(batch.jobs.single.state, JobState.done);
    expect(saved, 1);
    expect(
      DevLog.recentLines(200).any((l) => l.contains('simulated_failure=1')),
      isFalse,
    );
  });
}
