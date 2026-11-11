import 'dart:io';
import 'dart:typed_data';

import 'package:easysave/core/models.dart';
import 'package:easysave/services/backup/local_auto_backup.dart';
import 'package:easysave/services/download_claims.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/export_names.dart';
import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/media_header_service.dart';
import 'package:easysave/services/storage_guard.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _postId = '2118566677374022101';
const _gb = 1024 * 1024 * 1024;

/// Auto-backup runs after every terminal batch; it writes into one stable
/// support folder that lives for the whole file.
class _FakePaths extends PathProviderPlatform {
  _FakePaths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
}

ParsedPost _post() => ParsedPost(
  platform: 'x',
  id: _postId,
  url: 'https://x.com/i/status/$_postId',
  author: PostAuthor(name: 'author'),
  items: [
    MediaItem(type: 'video', url: 'https://video.twimg.com/ext_tw_video/1/pu/vid/720x1280/big.mp4'),
  ],
);

DownloadBatch _batch(String id) => DownloadBatch(
  batchId: id,
  album: 'EasySave',
  postUrl: 'https://x.com/i/status/$_postId',
  platform: 'x',
  postId: _postId,
  title: 'Large video',
  itemsJson: '[{"type":"video","url":"https://video.twimg.com/a.mp4"}]',
  jobs: [
    DownloadJob(
      key: '$id-1',
      label: '视频 1',
      filename: 'big.mp4',
      urls: ['https://video.twimg.com/a.mp4'],
      isImage: false,
      itemIndex: 1,
    ),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final manager = DownloadManager.instance;
  final locator = GalleryLocatorService.instance;
  late HistoryDb db;
  late Directory temp;
  final logs = <String>[];

  late Directory support;
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
    manager.clearBatchesForTesting();
    HistoryDb.resetInstanceForTesting();
    db = await HistoryDb.instance(dbPath: ':memory:');
    HistoryDb.setInstanceForTesting(db);
    await db.clear();
    locator.resetForTesting();
    // Overlay-like engine: no plugin permission, native index of the album.
    locator.nativeIndexReaderForTesting = (_) async => {'permission': 'denied', 'items': []};
    MediaHeaderService.headerReader = (_, _) async => Uint8List(0);
    temp = await Directory.systemTemp.createTemp('easysave_storage');
    manager.tempRootForTesting = () async => temp;
    LocalAutoBackup.resetThrottleForTest();
    manager.prepareStartForTesting = () async {};
    logs.clear();
    debugPrint = (message, {wrapWidth}) => logs.add(message ?? '');
  });

  tearDown(() async {
    debugPrint = debugPrintThrottled;
    for (final b in await manager.liveBatches()) {
      await DownloadClaims.release(b.batchId);
    }
    manager
      ..enqueueForTesting = null
      ..contentLengthProbeForTesting = null
      ..gallerySaveForTesting = null
      ..historyWriterForTesting = null
      ..albumProvenanceForTesting = null
      ..mediaSizeForTesting = null
      ..finishTimeoutForTesting = null
      ..historyRetryDelay = const Duration(seconds: 30)
      ..tempRootForTesting = null
      ..reparseForTesting = null
      ..prepareStartForTesting = null;
    StorageGuard.freeBytesReaderForTesting = null;
    MediaHeaderService.headerReader = null;
    manager.clearBatchesForTesting();
    locator.resetForTesting();
    HistoryDb.resetInstanceForTesting();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  /// A temp download of [bytes] in the job's task directory.
  Future<File> tempDownload(DownloadBatch batch, int bytes) async {
    final job = batch.jobs.single;
    final file = File(
      '${temp.path}/${downloadTempDirectory(batch.batchId, '${job.key}-try1')}/big.mp4',
    );
    await file.create(recursive: true);
    await file.writeAsBytes(Uint8List(bytes));
    job
      ..attempts = 1
      ..currentTaskId = '${job.key}-try1'
      ..state = JobState.active;
    return file;
  }

  group('storage guard', () {
    test('needs twice the size plus a margin and words it in GB', () {
      expect(requiredBytesForDownload(1000), 2000 + kStorageMarginBytes);
      expect(storageFullMessage(requiredBytesForDownload((1.02 * _gb).round())),
          '存储空间不足，需要约 2.3 GB');
      expect(storageFullMessage(), contains('存储空间不足'));
    });

    test('recognizes ENOSPC, SQLITE_FULL and plugin descriptions', () {
      expect(isStorageFullError(const FileSystemException('write', 'x',
          OSError('No space left on device', 28))), isTrue);
      expect(isStorageFullError(Exception(
          'DatabaseException(database or disk is full (code 13 SQLITE_FULL))')), isTrue);
      expect(isStorageFullError('java.io.IOException: write failed: ENOSPC'), isTrue);
      expect(isStorageFullError(const FileSystemException('write', 'x',
          OSError('Permission denied', 13))), isFalse);
      expect(isStorageFullError('HTTP 403'), isFalse);
    });

    test('unknown size or unknown free space never blocks', () async {
      StorageGuard.freeBytesReaderForTesting = () async => 10;
      expect(await StorageGuard.shortfall(null), isNull);
      StorageGuard.freeBytesReaderForTesting = () async => null;
      expect(await StorageGuard.shortfall(_gb), isNull);
      StorageGuard.freeBytesReaderForTesting = () async => 3 * _gb;
      expect(await StorageGuard.shortfall(_gb), isNull);
      StorageGuard.freeBytesReaderForTesting = () async => 2 * _gb;
      expect(await StorageGuard.shortfall(_gb), requiredBytesForDownload(_gb));
    });
  });

  test('disk full before the download: STORAGE_FULL, nothing fetched, post '
      'stays in history', () async {
    final size = (1.02 * _gb).round();
    StorageGuard.freeBytesReaderForTesting = () async => (1.5 * _gb).round();
    manager.contentLengthProbeForTesting = (_, _) async => size;
    var enqueued = 0;
    manager.enqueueForTesting = (_, _) async => enqueued++;

    final batch = await manager.startBatch(_post(), [0],
        album: 'EasySave', nameFor: (_, _, _) => 'big');
    final job = batch.jobs.single;
    expect(enqueued, 0);
    expect(job.state, JobState.failed);
    expect(job.errorCode, storageFullCode);
    expect(job.error, storageFullMessage(requiredBytesForDownload(size)));
    expect(batch.failureReason, '存储空间不足');
    final record = await db.getByPostId(_postId, platform: 'x');
    expect(record, isNotNull, reason: 'a failed post must stay in history');
    expect(record!.savedFiles, isEmpty);
    expect(logs.any((l) => l.contains('preflight') && l.contains(storageFullCode)), isTrue);
    expect(logs.any((l) => l.contains('cleanup bytes=')), isTrue);
  });

  test('disk full while writing: STORAGE_FULL, temp files removed', () async {
    final batch = _batch('enospc');
    manager.setBatchForTesting(batch);
    final file = await tempDownload(batch, 4096);
    final leftover = File('${file.parent.path}/partial.tmp')..writeAsBytesSync(Uint8List(100));
    manager.gallerySaveForTesting = (_, _) async => throw const FileSystemException(
        'write failed', 'album', OSError('No space left on device', 28));

    await manager.importFileForTesting(batch, batch.jobs.single, file.path);
    final job = batch.jobs.single;
    expect(job.state, JobState.failed);
    expect(job.errorCode, storageFullCode);
    expect(job.error, startsWith('存储空间不足'));
    expect(await file.exists(), isFalse);
    expect(await leftover.exists(), isFalse);
    expect(logs.any((l) => l.contains('cleanup bytes=4196')), isTrue);
    final record = await db.getByPostId(_postId, platform: 'x');
    expect(record, isNotNull);
    expect(batch.failureReason, '存储空间不足');
  });

  test('album write succeeds but the database is full: history is retried '
      'and written once space returns', () async {
    final batch = _batch('dbfull');
    manager.setBatchForTesting(batch);
    final file = await tempDownload(batch, 2048);
    manager.gallerySaveForTesting = (_, _) async =>
        (mediaId: '7001', title: 'x_${_postId}_1.mp4', relativePath: 'Movies/EasySave/');
    manager.historyRetryDelay = const Duration(milliseconds: 50);
    var diskFull = true;
    manager.historyWriterForTesting = (db, batch, recovered) async {
      if (diskFull) {
        throw Exception('database or disk is full (code 13 SQLITE_FULL)');
      }
      await writeBatchHistory(db, batch, recovered: recovered);
    };

    await manager.importFileForTesting(batch, batch.jobs.single, file.path);
    expect(batch.jobs.single.state, JobState.done);
    expect(batch.historyWritten, isFalse);
    expect(await db.getByPostId(_postId, platform: 'x'), isNull);
    expect(logs.where((l) => l.contains('event=write_retry')), hasLength(3));
    expect(logs.any((l) => l.contains('event=write_failed') && l.contains(storageFullCode)), isTrue);

    diskFull = false;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final record = await db.getByPostId(_postId, platform: 'x');
    expect(record!.savedFiles.single.mediaId, '7001');
    expect(batch.historyWritten, isTrue);
    expect(batch.failedCount, 0);
  });

  test('retry links a complete album copy instead of downloading again',
      () async {
    final batch = _batch('reuse');
    final job = batch.jobs.single
      ..state = JobState.failed
      ..error = '保存超时，请重试'
      ..fileBytes = 5000;
    manager.setBatchForTesting(batch);
    locator.nativeIndexReaderForTesting = (_) async => {
      'permission': 'denied',
      'items': [
        {
          'id': '8001',
          'title': cleanMediaFilename(_postId, 1, 'mp4'),
          'type': 'video',
          'owned': true,
          'relativePath': 'Movies/EasySave/',
        },
      ],
    };
    manager.albumProvenanceForTesting =
        (_) async => provenanceForBatchItem(batch, itemIndex: 1);
    manager.mediaSizeForTesting = (_, _) async => 5000;
    var enqueued = 0;
    manager.enqueueForTesting = (_, _) async => enqueued++;

    await manager.retryJob(batch, job);
    expect(enqueued, 0);
    expect(job.state, JobState.done);
    expect(job.mediaId, '8001');
    final record = await db.getByPostId(_postId, platform: 'x');
    expect(record!.savedFiles.single.mediaId, '8001');
    final live = await manager.liveBatches();
    expect(live.where((b) => b.failedCount > 0), isEmpty,
        reason: 'a successful retry leaves no failure behind');
    expect(logs.any((l) => l.contains('retry reused album copy')), isTrue);
  });

  test('retry downloads again when the album copy is incomplete', () async {
    final batch = _batch('partial');
    final job = batch.jobs.single
      ..state = JobState.failed
      ..fileBytes = 5000;
    manager.setBatchForTesting(batch);
    locator.nativeIndexReaderForTesting = (_) async => {
      'permission': 'denied',
      'items': [
        {'id': '8002', 'title': cleanMediaFilename(_postId, 1, 'mp4'), 'type': 'video', 'owned': true},
      ],
    };
    manager.albumProvenanceForTesting =
        (_) async => provenanceForBatchItem(batch, itemIndex: 1);
    manager.mediaSizeForTesting = (_, _) async => 1200;
    manager.reparseForTesting = (_) async => throw StateError('offline');
    var enqueued = 0;
    manager.enqueueForTesting = (_, _) async => enqueued++;

    await manager.retryJob(batch, job);
    expect(enqueued, 1);
    expect(logs.any((l) => l.contains('reason=size')), isTrue);
  });

  test('an import that outlives its timeout is recorded when the album copy '
      'finishes', () async {
    final batch = _batch('late');
    manager.setBatchForTesting(batch);
    final file = await tempDownload(batch, 1024);
    manager.finishTimeoutForTesting = const Duration(milliseconds: 30);
    manager.gallerySaveForTesting = (_, _) async {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      return (mediaId: '9001', title: 'x_${_postId}_1.mp4', relativePath: 'Movies/EasySave/');
    };

    await manager.importFileForTesting(batch, batch.jobs.single, file.path);
    expect(batch.jobs.single.state, JobState.failed);
    expect(batch.jobs.single.error, contains('超时'));

    await manager.lateImportForTesting(batch.jobs.single.key);
    expect(batch.jobs.single.state, JobState.done);
    expect(batch.failedCount, 0);
    final record = await db.getByPostId(_postId, platform: 'x');
    expect(record!.savedFiles.single.mediaId, '9001');
  });

  test('import budget grows with the file size', () {
    expect(finishTimeoutFor(null), kFinishFileTimeout);
    expect(finishTimeoutFor(_gb), kFinishFileTimeout + const Duration(seconds: 128));
  });
}
