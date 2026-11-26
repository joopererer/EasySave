import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:background_downloader/background_downloader.dart'
    show DownloadTask, ResumeData;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:easysave/core/dev_log.dart';
import 'package:easysave/core/models.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/settings.dart';
import 'package:easysave/services/transfer_client.dart';

class _FakeTransferClient extends TransferClient {
  final StreamController<TransferEvent> controller =
      StreamController<TransferEvent>.broadcast();
  final List<Map<String, dynamic>> enqueued = [];
  final Set<String> activeJobIds = {};
  final List<List<String>> ackedHistory = [];

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
    final id = jobId ?? '';
    if (!activeJobIds.add(id)) {
      return id;
    }
    enqueued.add({
      'jobId': id,
      'direction': direction,
      'category': category,
      'batchId': batchId,
      'pairId': pairId,
      'url': url,
      'mime': mime,
      'policyKey': policyKey,
      'provenance': provenance,
      'batchTotalCount': batchTotalCount,
    });
    return id;
  }

  @override
  Future<bool> claimHistoryWrite(String batchId) async => true;

  @override
  Future<bool> ackHistoryWritten(List<String> jobIds) async {
    ackedHistory.add(List<String>.from(jobIds));
    return true;
  }

  void dispose() {
    unawaited(controller.close());
  }
}

int _findHeaderEnd(List<int> bytes) {
  for (var i = 0; i <= bytes.length - 4; i++) {
    if (bytes[i] == 13 &&
        bytes[i + 1] == 10 &&
        bytes[i + 2] == 13 &&
        bytes[i + 3] == 10) {
      return i;
    }
  }
  return -1;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late Directory transfersDir;
  late HistoryDb testDb;
  late _FakeTransferClient fakeClient;
  late List<String> canceledTaskIds;
  late Map<String, ResumeData> resumeStore;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('p05_migration_test_');
    transfersDir = Directory('${tempDir.path}/transfers');
    await transfersDir.create(recursive: true);

    HistoryDb.resetInstanceForTesting();
    testDb = await HistoryDb.instance(dbPath: '${tempDir.path}/history.db');
    HistoryDb.setInstanceForTesting(testDb);

    fakeClient = _FakeTransferClient();
    canceledTaskIds = [];
    resumeStore = {};
    await DevLog.clear();

    final dm = DownloadManager.instance;
    dm.prepareStartForTesting = () async {};
    dm.transferClientForTesting = fakeClient;
    dm.transfersDirForTesting = () async => transfersDir;
    dm.useNewTransferPipelineForTesting = true;
    dm.settingsLoaderForTesting = () async =>
        AppSettings()..useNewTransferPipeline = true;
    dm.cancelTaskForTesting = (taskId) async {
      canceledTaskIds.add(taskId);
    };
    dm.getResumeDataForTesting = (taskId) async => resumeStore[taskId];
    dm.removeResumeDataForTesting = (taskId) async {
      resumeStore.remove(taskId);
    };
    dm.deleteLegacyRecordsForTesting = (_) async {};
    dm.allRecordsForTesting = (_) async => [];
    dm.moveFileForTesting = null;
  });

  tearDown(() async {
    final dm = DownloadManager.instance;
    dm.prepareStartForTesting = null;
    dm.transferClientForTesting = null;
    dm.transfersDirForTesting = null;
    dm.useNewTransferPipelineForTesting = null;
    dm.settingsLoaderForTesting = null;
    dm.cancelTaskForTesting = null;
    dm.getResumeDataForTesting = null;
    dm.removeResumeDataForTesting = null;
    dm.deleteLegacyRecordsForTesting = null;
    dm.allRecordsForTesting = null;
    dm.moveFileForTesting = null;
    fakeClient.dispose();
    HistoryDb.setInstanceForTesting(null);
    HistoryDb.resetInstanceForTesting();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> seedLegacyBatch(DownloadBatch batch) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'easysave_batch_${batch.batchId}',
      jsonEncode(batch.toJson()),
    );
    final index = prefs.getStringList('easysave_batches') ?? <String>[];
    if (!index.contains(batch.batchId)) {
      index.add(batch.batchId);
      await prefs.setStringList('easysave_batches', index);
    }
  }

  DownloadBatch makeLegacyBatch({
    String batchId = 'b_legacy_1',
    List<DownloadJob>? jobs,
    String source = DownloadBatch.sourceMain,
  }) {
    return DownloadBatch(
      batchId: batchId,
      album: 'EasySave',
      postUrl: 'https://www.xiaohongshu.com/explore/post123',
      platform: 'xhs',
      postId: 'post123',
      authorName: 'Tester',
      authorId: 'u1',
      title: 'Legacy Post',
      source: source,
      pipeline: DownloadBatch.pipelineLegacy,
      jobs:
          jobs ??
          [
            DownloadJob(
                key: '$batchId-0',
                label: 'video:mp4',
                filename: 'post123_1.mp4',
                urls: [
                  'https://sns-video-bd.xhscdn.com/v0.mp4',
                  'https://sns-video-bd.xhscdn.com/v1.mp4',
                ],
                isImage: false,
                itemIndex: 1,
              )
              ..candidateIndex = 1
              ..currentTaskId = 'task_legacy_0'
              ..expectedBytes = 65536
              ..state = JobState.paused,
          ],
    );
  }

  group('Default pipeline setting', () {
    test(
      'defaults to true on fresh install and upgrade, preserves explicit false',
      () async {
        SharedPreferences.setMockInitialValues({});
        final fresh = await AppSettings.load();
        expect(fresh.useNewTransferPipeline, isTrue);

        SharedPreferences.setMockInitialValues({'albumName': 'EasySave'});
        final upgraded = await AppSettings.load();
        expect(upgraded.useNewTransferPipeline, isTrue);

        SharedPreferences.setMockInitialValues({
          'useNewTransferPipeline': false,
        });
        final explicitOff = await AppSettings.load();
        expect(explicitOff.useNewTransferPipeline, isFalse);
      },
    );
  });

  group('Legacy task migration', () {
    test(
      'migrates ResumeData temp file to .part and resumes byte-for-byte',
      () async {
        final fullBytes = Uint8List.fromList(
          List<int>.generate(65536, (i) => (i * 31 + 7) & 0xFF),
        );
        const splitOffset = 20480;

        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((req) async {
          final range = req.headers.value('range');
          if (range != null && range.startsWith('bytes=')) {
            final start = int.parse(range.substring(6).split('-').first);
            req.response.statusCode = HttpStatus.partialContent;
            req.response.contentLength = fullBytes.length - start;
            req.response.headers.set(
              'content-range',
              'bytes $start-${fullBytes.length - 1}/${fullBytes.length}',
            );
            req.response.add(fullBytes.sublist(start));
          } else {
            req.response.statusCode = HttpStatus.ok;
            req.response.add(fullBytes);
          }
          await req.response.close();
        });

        final legacyTemp = File('${tempDir.path}/legacy_tmp_0.part');
        await legacyTemp.writeAsBytes(fullBytes.sublist(0, splitOffset));

        resumeStore['task_legacy_0'] = ResumeData(
          DownloadTask(
            taskId: 'task_legacy_0',
            url: 'https://sns-video-bd.xhscdn.com/v1.mp4',
            filename: 'post123_1.mp4',
          ),
          legacyTemp.path,
          splitOffset,
          'etag-1',
        );

        final batch = makeLegacyBatch();
        await seedLegacyBatch(batch);

        await DownloadManager.instance.reconcileForTesting();

        // Legacy task was cancelled via unique gate.
        expect(canceledTaskIds, contains('task_legacy_0'));

        // Enqueued to TransferService with same batch, candidateIndex=1, provenance.
        expect(fakeClient.enqueued.length, 1);
        final enq = fakeClient.enqueued.first;
        final jobId = enq['jobId'] as String;
        expect(jobId, 'xfer_b_legacy_1-0_c1');
        expect(enq['batchId'], 'b_legacy_1');
        expect(enq['url'], 'https://sns-video-bd.xhscdn.com/v1.mp4');
        expect(((enq['provenance'] as Map)['source'] as Map)['id'], 'post123');

        // Temp file moved to transfers/<jobId>.part with exact length.
        final partFile = File('${transfersDir.path}/$jobId.part');
        expect(await partFile.exists(), isTrue);
        expect(await legacyTemp.exists(), isFalse);
        expect(await partFile.length(), splitOffset);

        // Resume from .part length via real TCP/HTTP Range request and verify byte-for-byte equality.
        final partLen = await partFile.length();
        final socket = await Socket.connect(
          InternetAddress.loopbackIPv4,
          server.port,
        );
        socket.write(
          'GET /video.mp4 HTTP/1.1\r\n'
          'Host: 127.0.0.1:${server.port}\r\n'
          'Range: bytes=$partLen-\r\n'
          'Connection: close\r\n\r\n',
        );
        await socket.flush();
        final rawResp = await socket.fold<List<int>>(
          [],
          (acc, c) => acc..addAll(c),
        );
        await socket.close();
        final sep = _findHeaderEnd(rawResp);
        expect(sep, greaterThan(0));
        final headerStr = utf8.decode(rawResp.sublist(0, sep));
        expect(headerStr, contains('206 Partial Content'));
        final rest = rawResp.sublist(sep + 4);
        final raf = await partFile.open(mode: FileMode.append);
        await raf.writeFrom(rest);
        await raf.close();
        expect(await partFile.readAsBytes(), equals(fullBytes));

        // Batch pipeline persisted as transfer.
        final prefs = await SharedPreferences.getInstance();
        final persisted = DownloadBatch.fromJson(
          (jsonDecode(prefs.getString('easysave_batch_b_legacy_1')!) as Map)
              .cast<String, Object?>(),
        );
        expect(persisted.usesNewTransferPipeline, isTrue);

        // Log emitted with exact prefix and fields.
        expect(
          DevLog.recentLines(200).any(
            (l) =>
                l.contains('[V16DL]') &&
                l.contains(
                  'legacy_migrated batch=b_legacy_1 jobs=1 '
                  'resumed=1 from_zero=0 kept_legacy=0 bytes_moved=$splitOffset',
                ),
          ),
          isTrue,
        );
      },
    );

    test('enqueues from 0 when no ResumeData or temp file exists', () async {
      final batch = makeLegacyBatch(batchId: 'b_no_tmp');
      await seedLegacyBatch(batch);

      await DownloadManager.instance.reconcileForTesting();

      expect(canceledTaskIds, contains('task_legacy_0'));
      expect(fakeClient.enqueued.length, 1);
      final jobId = fakeClient.enqueued.first['jobId'] as String;
      final partFile = File('${transfersDir.path}/$jobId.part');
      expect(await partFile.exists(), isFalse);
      expect(
        DevLog.recentLines(200).any(
          (l) =>
              l.contains('[V16DL]') &&
              l.contains(
                'legacy_migrated batch=b_no_tmp jobs=1 '
                'resumed=0 from_zero=1 kept_legacy=0 bytes_moved=0',
              ),
        ),
        isTrue,
      );
    });

    test(
      'survives kill mid-migration without duplicating tasks or losing .part',
      () async {
        final jobId = 'xfer_b_kill-0_c1';
        final alreadyMovedPart = File('${transfersDir.path}/$jobId.part');
        await alreadyMovedPart.writeAsBytes(List<int>.filled(4096, 42));

        // Batch was still persisted as legacy (simulating kill before _persist).
        final batch = makeLegacyBatch(batchId: 'b_kill');
        await seedLegacyBatch(batch);

        await DownloadManager.instance.reconcileForTesting();

        expect(fakeClient.enqueued.length, 1);
        expect(await alreadyMovedPart.length(), 4096);

        // Second restart: batch is now transfer, must not migrate again.
        await DownloadManager.instance.reconcileForTesting();
        expect(fakeClient.enqueued.length, 1);
        expect(
          DevLog.recentLines(
            200,
          ).where((l) => l.contains('legacy_migrated batch=b_kill')).length,
          1,
        );
      },
    );

    test(
      'Live pair with one done+saved and one unfinished keeps pairing intact',
      () async {
        final stillJob =
            DownloadJob(
                key: 'b_live-0',
                label: 'img:jpg',
                filename: 'post123_1.jpg',
                urls: ['https://sns-webpic-qc.xhscdn.com/still.jpg'],
                isImage: true,
                itemIndex: 1,
                isLivePhoto: true,
              )
              ..state = JobState.done
              ..saved = true
              ..mediaId = 'media_still_1';

        final clipJob =
            DownloadJob(
                key: 'b_live-1',
                label: 'video:mp4',
                filename: 'post123_1.mp4',
                urls: ['https://sns-video-bd.xhscdn.com/clip.mp4'],
                isImage: false,
                itemIndex: 1,
                isLivePhoto: true,
              )
              ..currentTaskId = 'task_clip_1'
              ..state = JobState.paused;

        final batch = makeLegacyBatch(
          batchId: 'b_live',
          jobs: [stillJob, clipJob],
        );
        await seedLegacyBatch(batch);

        await DownloadManager.instance.reconcileForTesting();

        // Only the unfinished clip job is enqueued; still job is not re-downloaded.
        expect(fakeClient.enqueued.length, 1);
        final enq = fakeClient.enqueued.first;
        expect(enq['jobId'], 'xfer_b_live-1');
        // Scheduler pairId is null so it doesn't deadlock waiting for a partner in TransferService.
        expect(enq['pairId'], isNull);
        // Provenance still carries pairId for XMP & History pairing.
        expect(jsonEncode(enq['provenance']), contains('post123#1'));
      },
    );

    test('does not migrate when new pipeline switch is off', () async {
      DownloadManager.instance.useNewTransferPipelineForTesting = false;
      final batch = makeLegacyBatch(batchId: 'b_off');
      await seedLegacyBatch(batch);

      await DownloadManager.instance.reconcileForTesting();

      expect(fakeClient.enqueued, isEmpty);
      final prefs = await SharedPreferences.getInstance();
      final persisted = DownloadBatch.fromJson(
        (jsonDecode(prefs.getString('easysave_batch_b_off')!) as Map)
            .cast<String, Object?>(),
      );
      expect(persisted.usesNewTransferPipeline, isFalse);
    });

    test('keeps legacy pipeline when moving temp file fails', () async {
      final legacyTemp = File('${tempDir.path}/legacy_fail.part');
      await legacyTemp.writeAsBytes([1, 2, 3, 4]);
      resumeStore['task_legacy_0'] = ResumeData(
        DownloadTask(
          taskId: 'task_legacy_0',
          url: 'https://sns-video-bd.xhscdn.com/v1.mp4',
          filename: 'post123_1.mp4',
        ),
        legacyTemp.path,
        4,
      );
      DownloadManager.instance.moveFileForTesting = (src, dst) async {
        throw const FileSystemException('Disk error');
      };

      final batch = makeLegacyBatch(batchId: 'b_move_fail');
      await seedLegacyBatch(batch);

      await DownloadManager.instance.reconcileForTesting();

      expect(fakeClient.enqueued, isEmpty);
      final prefs = await SharedPreferences.getInstance();
      final persisted = DownloadBatch.fromJson(
        (jsonDecode(prefs.getString('easysave_batch_b_move_fail')!) as Map)
            .cast<String, Object?>(),
      );
      expect(persisted.usesNewTransferPipeline, isFalse);
      expect(
        DevLog.recentLines(200).any(
          (l) =>
              l.contains('[V16DL]') &&
              l.contains(
                'legacy_migrated batch=b_move_fail jobs=0 '
                'resumed=0 from_zero=0 kept_legacy=1 bytes_moved=0',
              ),
        ),
        isTrue,
      );
    });
  });
}
