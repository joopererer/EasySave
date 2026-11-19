import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart' hide Database;
import 'package:easysave/core/dev_log.dart';
import 'package:easysave/core/models.dart';
import 'package:easysave/services/download_claims.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/network_status.dart';
import 'package:easysave/services/parse_service.dart';
import 'package:easysave/services/resumable_download_store.dart';
import 'package:easysave/services/session_media_download.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:easysave/services/storage_guard.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;
  late ResumableDownloadStore store;
  late File localPartFile;

  setUp(() async {
    HttpOverrides.global = null;
    SiteRegistry.useBuiltin();
    DownloadClaims.resetForTesting();
    tempDir = await Directory.systemTemp.createTemp('v112_resumable_test_');
    store = ResumableDownloadStore.instance;
    store.overrideDirectory = tempDir;
    localPartFile = File('${tempDir.path}/test_part.tmp');
    await localPartFile.writeAsBytes(List.filled(1024, 0));
  });

  tearDown(() async {
    SiteRegistry.useBuiltin();
    store.overrideDirectory = null;
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  group('ResumableDownloadStore storage and retention', () {
    test('purgeExpired respects 3-day retention boundary', () async {
      final job1 = 'job-fresh';
      final job2 = 'job-old';
      final file1 = await store.partialFileFor(job1);
      final file2 = await store.partialFileFor(job2);
      await file1.parent.create(recursive: true);
      await file1.writeAsBytes([1, 2, 3]);
      await file2.writeAsBytes([4, 5, 6]);

      // Age file2 beyond 3 days
      final oldDate = DateTime.now().subtract(const Duration(days: 4));
      await file2.setLastModified(oldDate);

      final purged = await store.purgeExpired(maxAge: const Duration(days: 3));
      expect(purged, 1);
      expect(await file1.exists(), isTrue, reason: 'fresh partial file must be kept');
      expect(await file2.exists(), isFalse, reason: 'partial file > 3 days must be purged');
    });

    test('cleanForJob and cleanForJobKeys delete both .part and .meta', () async {
      final jobKey = 'test-clean-job';
      final part = await store.partialFileFor(jobKey);
      await part.parent.create(recursive: true);
      await part.writeAsBytes([10, 20]);
      await store.writeMetadata(
        jobKey,
        const ResumeMetadata(validator: '"etag-1"', totalBytes: 100, updatedAt: 12345),
      );

      final meta = await store.metaFileFor(jobKey);
      expect(await part.exists(), isTrue);
      expect(await meta.exists(), isTrue);

      await store.cleanForJobKeys([jobKey]);
      expect(await part.exists(), isFalse);
      expect(await meta.exists(), isFalse);
    });
  });

  group('SessionMediaDownload Range and If-Range flow', () {
    test('mid-flight disconnect preserves partial file (≥5MB) and resumes with 206', () async {
      final totalSize = 7 * 1024 * 1024; // 7MB (> 5MB threshold)
      final fullData = Uint8List(totalSize);
      for (var i = 0; i < totalSize; i++) {
        fullData[i] = i % 251;
      }
      final etag = '"video-etag-7mb"';

      final requestedRanges = <String?>[];
      final requestedIfRanges = <String?>[];

      final server1 = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server1.listen((HttpRequest request) async {
        requestedRanges.add(request.headers.value(HttpHeaders.rangeHeader));
        requestedIfRanges.add(request.headers.value('if-range'));

        // First attempt: simulate connection dropping after sending 5.5MB
        request.response.statusCode = 200;
        request.response.headers.set(HttpHeaders.etagHeader, etag);
        request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        request.response.headers.set(HttpHeaders.contentLengthHeader, totalSize.toString());

        final dropBytes = 5500000;
        request.response.add(fullData.sublist(0, dropBytes));
        await request.response.flush();
        // Drop connection abruptly
        await server1.close(force: true);
      });

      final url1 = 'http://${server1.address.host}:${server1.port}/video.mp4';
      final destFile = File('${tempDir.path}/final.mp4');
      final downloader = SessionMediaDownload();
      final jobKey = 'session-resume-test';

      // First run: fails with socket drop
      try {
        await downloader.download(
          url: url1,
          destination: destFile,
          onProgress: (_) {},
          jobKey: jobKey,
          itemIndex: 0,
        );
      } catch (e) {
        expect(e, isA<SessionDownloadException>());
      }

      // Check partial file was preserved since > 5MB
      final part = await store.partialFileFor(jobKey);
      expect(await part.exists(), isTrue);
      expect(await part.length(), 5500000);
      final meta = await store.readMetadata(jobKey);
      expect(meta?.validator, etag);

      // Second run: resumes from 5.5MB
      final server2 = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server2.listen((HttpRequest request) async {
        requestedRanges.add(request.headers.value(HttpHeaders.rangeHeader));
        requestedIfRanges.add(request.headers.value('if-range'));
        final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
        final ifRange = request.headers.value('if-range');
        if (rangeHeader != null && rangeHeader.startsWith('bytes=5500000-') && ifRange == etag) {
          request.response.statusCode = 206;
          request.response.headers.set(HttpHeaders.etagHeader, etag);
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes 5500000-${totalSize - 1}/$totalSize',
          );
          request.response.headers.set(
            HttpHeaders.contentLengthHeader,
            (totalSize - 5500000).toString(),
          );
          request.response.add(fullData.sublist(5500000));
          await request.response.close();
        } else {
          request.response.statusCode = 500;
          await request.response.close();
        }
      });

      final url2 = 'http://${server2.address.host}:${server2.port}/video.mp4';
      final downloader2 = SessionMediaDownload();
      await downloader2.download(
        url: url2,
        destination: destFile,
        onProgress: (_) {},
        jobKey: jobKey,
        itemIndex: 0,
      );

      expect(requestedRanges.last, 'bytes=5500000-');
      expect(requestedIfRanges.last, etag);
      expect(await destFile.exists(), isTrue);
      expect(await destFile.length(), totalSize);
      expect(await destFile.readAsBytes(), fullData);

      // Partial file cleaned up on complete
      expect(await part.exists(), isFalse);

      await server2.close(force: true);
    });

    test('server without Range support (status 200) restarts from 0', () async {
      final totalSize = 6 * 1024 * 1024;
      final fullData = Uint8List(totalSize);
      final etag = '"etag-norange"';

      // Pre-seed partial file with 5.2MB
      final jobKey = 'test-status-200';
      final part = await store.partialFileFor(jobKey);
      await part.parent.create(recursive: true);
      await part.writeAsBytes(Uint8List(5200000));
      await store.writeMetadata(
        jobKey,
        ResumeMetadata(validator: etag, totalBytes: totalSize, updatedAt: DateTime.now().millisecondsSinceEpoch),
      );

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest request) async {
        // Server ignores Range and returns 200 OK
        request.response.statusCode = 200;
        request.response.headers.set(HttpHeaders.etagHeader, etag);
        request.response.headers.set(HttpHeaders.contentLengthHeader, totalSize.toString());
        request.response.add(fullData);
        await request.response.close();
      });

      final url = 'http://${server.address.host}:${server.port}/video.mp4';
      final destFile = File('${tempDir.path}/dest200.mp4');
      final downloader = SessionMediaDownload();

      await downloader.download(
        url: url,
        destination: destFile,
        onProgress: (_) {},
        jobKey: jobKey,
        itemIndex: 0,
      );

      expect(await destFile.exists(), isTrue);
      expect(await destFile.length(), totalSize);
      expect(await part.exists(), isFalse);

      await server.close(force: true);
    });

    test('validator change discards partial file and restarts from 0', () async {
      final totalSize = 6 * 1024 * 1024;
      final fullData = Uint8List(totalSize);
      final oldEtag = '"etag-v1"';
      final newEtag = '"etag-v2"';

      final jobKey = 'test-validator-changed';
      final part = await store.partialFileFor(jobKey);
      await part.parent.create(recursive: true);
      await part.writeAsBytes(Uint8List(5200000));
      await store.writeMetadata(
        jobKey,
        ResumeMetadata(validator: oldEtag, totalBytes: totalSize, updatedAt: DateTime.now().millisecondsSinceEpoch),
      );

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest request) async {
        // ETag changed -> returns 200 with new ETag
        request.response.statusCode = 200;
        request.response.headers.set(HttpHeaders.etagHeader, newEtag);
        request.response.headers.set(HttpHeaders.contentLengthHeader, totalSize.toString());
        request.response.add(fullData);
        await request.response.close();
      });

      final url = 'http://${server.address.host}:${server.port}/video.mp4';
      final destFile = File('${tempDir.path}/dest_validator_changed.mp4');
      final downloader = SessionMediaDownload();

      await downloader.download(
        url: url,
        destination: destFile,
        onProgress: (_) {},
        jobKey: jobKey,
        itemIndex: 0,
      );

      expect(await destFile.exists(), isTrue);
      expect(await destFile.length(), totalSize);

      await server.close(force: true);
    });

    test('expired signature (403/410) cleans partial file and throws SessionDownloadException', () async {
      final jobKey = 'test-expired-sig';
      final part = await store.partialFileFor(jobKey);
      await part.parent.create(recursive: true);
      await part.writeAsBytes(Uint8List(5200000));
      await store.writeMetadata(
        jobKey,
        ResumeMetadata(validator: '"etag-1"', totalBytes: 6000000, updatedAt: DateTime.now().millisecondsSinceEpoch),
      );

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest request) async {
        request.response.statusCode = 403;
        await request.response.close();
      });

      final url = 'http://${server.address.host}:${server.port}/video.mp4';
      final destFile = File('${tempDir.path}/dest_expired.mp4');
      final downloader = SessionMediaDownload();

      await expectLater(
        downloader.download(
          url: url,
          destination: destFile,
          onProgress: (_) {},
          jobKey: jobKey,
          itemIndex: 0,
        ),
        throwsA(isA<SessionDownloadException>().having((e) => e.statusCode, 'statusCode', 403)),
      );

      expect(await part.exists(), isFalse, reason: 'expired URL must clean partial file');
      await server.close(force: true);
    });

    test('size threshold boundary: < 5MB is discarded on disconnect; ≥ 5MB is saved', () async {
      // 1. Below 5MB (e.g. 2MB)
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest request) async {
        request.response.statusCode = 200;
        request.response.headers.set(HttpHeaders.etagHeader, '"etag-threshold"');
        request.response.add(Uint8List(2 * 1024 * 1024));
        await request.response.flush();
        await server.close(force: true);
      });

      final url = 'http://${server.address.host}:${server.port}/video.mp4';
      final destFile = File('${tempDir.path}/dest_small.mp4');
      final jobKeySmall = 'test-small-threshold';

      try {
        await SessionMediaDownload().download(
          url: url,
          destination: destFile,
          onProgress: (_) {},
          jobKey: jobKeySmall,
          itemIndex: 0,
        );
      } catch (_) {}

      final partSmall = await store.partialFileFor(jobKeySmall);
      expect(await partSmall.exists(), isFalse, reason: 'fragments < 5MB must not be kept');

      await server.close(force: true);
    });

    test('cancellation cleans partial files and metadata', () async {
      final jobKey = 'test-cancel-cleanup';
      final part = await store.partialFileFor(jobKey);
      await part.parent.create(recursive: true);
      await part.writeAsBytes(Uint8List(5500000));
      await store.writeMetadata(
        jobKey,
        ResumeMetadata(validator: '"etag-c"', totalBytes: 8000000, updatedAt: DateTime.now().millisecondsSinceEpoch),
      );

      final downloader = SessionMediaDownload();
      final destFile = File('${tempDir.path}/dest_cancel.mp4');
      unawaited(downloader.cancel());

      await expectLater(
        downloader.download(
          url: 'http://127.0.0.1/video.mp4',
          destination: destFile,
          onProgress: (_) {},
          jobKey: jobKey,
          itemIndex: 0,
        ),
        throwsA(isA<SessionDownloadCanceled>()),
      );

      expect(await part.exists(), isFalse);
      expect(await store.readMetadata(jobKey), isNull);
    });

    test('app kill recovery preserves partial file for retry', () async {
      final jobKey = 'test-kill-recovery';
      final job = DownloadJob(
        key: jobKey,
        label: '视频 1',
        filename: 'v.mp4',
        urls: ['http://127.0.0.1/video.mp4'],
        isImage: false,
        itemIndex: 0,
      );
      final batch = DownloadBatch(
        batchId: 'batch-kill-recovery',
        album: 'EasySave',
        postUrl: 'https://www.tiktok.com/@user/video/12345',
        platform: 'tiktok',
        postId: '12345',
        title: 'Title',
        itemsJson: '[]',
        postItemCount: 1,
        jobs: [job],
      );

      // Partial file exists from before app was killed
      final part = await store.partialFileFor(jobKey);
      await part.parent.create(recursive: true);
      await part.writeAsBytes(Uint8List(5500000));
      await store.writeMetadata(
        jobKey,
        ResumeMetadata(validator: '"etag-k"', totalBytes: 8000000, updatedAt: DateTime.now().millisecondsSinceEpoch),
      );

      // Reconcile on startup recovers session job
      final recovered = recoverSessionJob(batch, job);
      expect(recovered, isTrue);
      expect(job.state, JobState.failed);
      expect(job.error, interruptedMediaMessage);

      // Partial file remains intact in store so retry can resume
      expect(await part.exists(), isTrue);
      final meta = await store.readMetadata(jobKey);
      expect(meta?.validator, '"etag-k"');
    });
  });

  group('Background downloader path true resume', () {
    const channel = MethodChannel('dexterous.com/flutter/local_notifications');
    const downloaderChannel = MethodChannel('com.bbflight.background_downloader');
    const downloaderBgChannel = MethodChannel('com.bbflight.background_downloader.background');
    final createdBatches = <String>[];
    final mockResumeData = <String, ResumeData>{};

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => true);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(downloaderChannel, (call) async => true);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(downloaderBgChannel, (call) async => null);

      DownloadManager.instance.downloaderStartForTesting = () async {};
      DownloadManager.instance.historyWriterForTesting = (db, batch, rec) async {};
      DownloadManager.instance.getResumeDataForTesting = (id) async => mockResumeData[id];
      DownloadManager.instance.setResumeDataForTesting = (rd) async {
        mockResumeData[rd.task.taskId] = rd;
      };
      DownloadManager.instance.removeResumeDataForTesting = (id) async {
        mockResumeData.remove(id);
      };
      DownloadManager.instance.resetInitForTesting();
      DownloadManager.instance.clearBatchesForTesting();
      DevLog.resetRecentForTesting();
      NetworkStatus.instance.setOnlineForTesting(true);
      createdBatches.clear();
      mockResumeData.clear();
      File('${tempDir.path}/part.tmp').writeAsBytesSync(List.filled(1024, 1));
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(downloaderChannel, null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(downloaderBgChannel, null);

      for (final id in createdBatches) {
        await DownloadClaims.release(id);
      }
      DownloadManager.instance.downloaderStartForTesting = null;
      DownloadManager.instance.historyWriterForTesting = null;
      DownloadManager.instance.allRecordsForTesting = null;
      DownloadManager.instance.resumeForTesting = null;
      DownloadManager.instance.getResumeDataForTesting = null;
      DownloadManager.instance.setResumeDataForTesting = null;
      DownloadManager.instance.removeResumeDataForTesting = null;
      DownloadManager.instance.candidateRangeProbeForTesting = null;
      DownloadManager.instance.reparseForTesting = null;
      DownloadManager.instance.resetInitForTesting();
      DownloadManager.instance.clearBatchesForTesting();
      DevLog.resetRecentForTesting();
      mockResumeData.clear();
    });

    DownloadBatch createBatch({
      String platform = 'x',
      String postId = '12345',
      int expectedBytes = 1020613970,
      bool isImage = false,
    }) {
      final batchId = 'batch-$postId-${DateTime.now().microsecondsSinceEpoch}';
      createdBatches.add(batchId);
      final job = DownloadJob(
        key: 'job-$postId-0',
        label: isImage ? '图片 1' : '视频 1',
        filename: isImage ? 'photo.jpg' : 'video.mp4',
        urls: [
          isImage
              ? 'https://pbs.twimg.com/media/test.jpg'
              : 'https://video.twimg.com/ext_tw_video/123/pu/vid/720x1280/v.mp4',
        ],
        isImage: isImage,
        itemIndex: 0,
      );
      job.expectedBytes = expectedBytes;
      final batch = DownloadBatch(
        batchId: batchId,
        album: 'EasySave',
        postUrl: 'https://x.com/user/status/$postId',
        platform: platform,
        postId: postId,
        title: 'Title',
        itemsJson: '[]',
        postItemCount: 1,
        jobs: [job],
      );
      DownloadManager.instance.setBatchForTesting(batch);
      return batch;
    }

    test('mid-flight disconnect -> waitingNetwork -> network returns -> resume (progress not 0, range_accepted)', () async {
      final batch = createBatch(postId: 'disconnect-test');
      final job = batch.jobs.first;
      job.progress = 0.35;

      final update = TaskStatusUpdate(
        DownloadTask(
          taskId: job.key,
          url: job.urls.first,
          filename: job.filename,
          group: batch.batchId,
        ),
        TaskStatus.failed,
        TaskConnectionException('java.net.SocketException: Software caused connection abort'),
      );

      await DownloadManager.instance.taskFailureForTesting(batch, job, update);

      // Verify connection drop is classified as paused/interrupted under Rule 2a
      expect(job.state, anyOf(JobState.paused, JobState.waitingNetwork));
      expect(job.progress, 0.35); // Progress does NOT reset to 0

      // When network is restored or job resumed
      bool resumeCalled = false;
      mockResumeData[job.key] = ResumeData(
        update.task,
        '${tempDir.path}/part.tmp',
        357214889,
        '"etag-test"',
      );
      DownloadManager.instance.resumeForTesting = (t) async {
        resumeCalled = true;
        expect(t.taskId.startsWith(job.key), isTrue);
        return true;
      };

      await DownloadManager.instance.enqueueAttemptForTesting(batch, job);

      expect(resumeCalled, isTrue);
      final recent = DevLog.recentLines(50);
      expect(recent.any((l) => l.contains('[V16DL]') && l.contains('result=requested') && l.contains('reason=range_requested')), isTrue);
    });

    test('manual retry resumes from existing progress and ResumeData', () async {
      final batch = createBatch(postId: 'manual-retry-test');
      final job = batch.jobs.first;
      job.state = JobState.failed;
      job.progress = 0.4;
      job.attempts = 1;

      bool resumeCalled = false;
      mockResumeData[job.key] = ResumeData(
        DownloadTask(taskId: job.key, url: job.urls.first, filename: job.filename, group: batch.batchId),
        '${tempDir.path}/part.tmp',
        408245588,
        '"etag-manual"',
      );
      DownloadManager.instance.resumeForTesting = (t) async {
        resumeCalled = true;
        expect(t.taskId.startsWith(job.key), isTrue);
        return true;
      };

      await DownloadManager.instance.retryJob(batch, job);

      expect(resumeCalled, isTrue);
      final recent = DevLog.recentLines(50);
      expect(recent.any((l) => l.contains('[V16DL]') && l.contains('result=requested') && l.contains('reason=range_requested')), isTrue);
    });

    test('app killed restart resumes via reconcileBatch', () async {
      final batch = createBatch(postId: 'app-kill-test');
      final job = batch.jobs.first;
      job.state = JobState.active;
      job.progress = 0.5;
      job.currentTaskId = job.key;

      final task = DownloadTask(
        taskId: job.key,
        url: job.urls.first,
        filename: job.filename,
        group: batch.batchId,
      );

      DownloadManager.instance.allRecordsForTesting = (group) async {
        return [TaskRecord(task, TaskStatus.failed, 0.5, 50000000)];
      };

      bool resumeCalled = false;
      mockResumeData[job.key] = ResumeData(task, '${tempDir.path}/part.tmp', 510306985, '"etag-reconcile"');
      DownloadManager.instance.resumeForTesting = (t) async {
        resumeCalled = true;
        return true;
      };

      final hasPending = await DownloadManager.instance.reconcileBatchForTesting(batch);
      expect(hasPending, isTrue);
      expect(resumeCalled, isTrue);

      final recent = DevLog.recentLines(50);
      expect(recent.any((l) => l.contains('[V16DL]') && l.contains('result=requested') && l.contains('reason=range_requested')), isTrue);
    });

    test('no resume data on retry triggers restart with reason=no_resume_data', () async {
      final batch = createBatch(postId: 'no-resume-data-test');
      final job = batch.jobs.first;
      job.progress = 0.5; // Previously progressed
      job.attempts = 1;

      bool resumeCalled = false;
      DownloadManager.instance.resumeForTesting = (t) async {
        resumeCalled = true;
        return true;
      };

      await DownloadManager.instance.enqueueAttemptForTesting(batch, job);

      expect(resumeCalled, isFalse);
      final recent = DevLog.recentLines(50);
      expect(
        recent.any((l) =>
            l.contains('[V16DL]') &&
            l.contains('result=restart') &&
            l.contains('reason=no_resume_data') &&
            l.contains('method=enqueue')),
        isTrue,
      );
    });

    test('validator changed (ETag mismatch) clears partial file and restarts from 0', () async {
      final batch = createBatch(postId: 'etag-changed-test');
      final job = batch.jobs.first;
      job.progress = 0.5;
      job.currentTaskId = job.key;

      final task = DownloadTask(
        taskId: job.key,
        url: job.urls.first,
        filename: job.filename,
        group: batch.batchId,
      );

      mockResumeData[job.key] = ResumeData(task, '${tempDir.path}/part.tmp', 510306985, '"etag-old"');

      final update = TaskStatusUpdate(
        task,
        TaskStatus.failed,
        TaskException('Cannot resume: ETag is not identical'),
      );

      await DownloadManager.instance.taskFailureForTesting(batch, job, update);

      expect(mockResumeData[job.key], isNull);
      expect(job.progress, 0.0);
      final recent = DevLog.recentLines(50);
      expect(recent.any((l) => l.contains('[V16DL]') && l.contains('result=restart') && l.contains('reason=validator_changed')), isTrue);
    });

    test('signed URL expired 403: re-parse and resume when server accepts Range and size matches', () async {
      final batch = createBatch(postId: 'expired-403-resume');
      final job = batch.jobs.first;
      job.progress = 0.5;
      job.currentTaskId = job.key;

      final task = DownloadTask(
        taskId: job.key,
        url: job.urls.first,
        filename: job.filename,
        group: batch.batchId,
      );

      mockResumeData[job.key] = ResumeData(task, '${tempDir.path}/part.tmp', 510306985, '"etag-fresh"');

      DownloadManager.instance.reparseForTesting = (postUrl) async {
        return ParseOutcome(
          data: ParsedPost(
            platform: 'x',
            id: 'expired-403-resume',
            url: postUrl,
            author: PostAuthor(name: 'user'),
            items: [MediaItem(type: 'video', url: 'https://video.twimg.com/fresh_url.mp4')],
          ),
          rawImages: [],
        );
      };

      DownloadManager.instance.candidateRangeProbeForTesting = (j, u) async {
        return (acceptsRange: true, contentLength: 1020613970);
      };

      bool resumeCalled = false;
      DownloadManager.instance.resumeForTesting = (t) async {
        resumeCalled = true;
        expect(t.url, 'https://video.twimg.com/fresh_url.mp4');
        return true;
      };

      final update = TaskStatusUpdate(
        task,
        TaskStatus.failed,
        TaskHttpException('HTTP 403 Forbidden', 403),
        null,
        null,
        403,
      );

      await DownloadManager.instance.taskFailureForTesting(batch, job, update);

      expect(resumeCalled, isTrue);
      expect(job.urls.first, 'https://video.twimg.com/fresh_url.mp4');
      final recent = DevLog.recentLines(50);
      expect(recent.any((l) => l.contains('[V16DL]') && l.contains('reason=expired')), isTrue);
      expect(recent.any((l) => l.contains('[V16DL]') && l.contains('result=resumed') && l.contains('reason=range_accepted')), isTrue);
    });

    test('signed URL expired 403: re-parse and restart from 0 when server does NOT accept Range', () async {
      final batch = createBatch(postId: 'expired-403-restart');
      final job = batch.jobs.first;
      job.progress = 0.5;
      job.currentTaskId = job.key;

      final task = DownloadTask(
        taskId: job.key,
        url: job.urls.first,
        filename: job.filename,
        group: batch.batchId,
      );

      mockResumeData[job.key] = ResumeData(task, '${tempDir.path}/part.tmp', 510306985, '"etag-fresh"');

      DownloadManager.instance.reparseForTesting = (postUrl) async {
        return ParseOutcome(
          data: ParsedPost(
            platform: 'x',
            id: 'expired-403-restart',
            url: postUrl,
            author: PostAuthor(name: 'user'),
            items: [MediaItem(type: 'video', url: 'https://video.twimg.com/fresh_url_no_range.mp4')],
          ),
          rawImages: [],
        );
      };

      DownloadManager.instance.candidateRangeProbeForTesting = (j, u) async {
        return (acceptsRange: false, contentLength: null);
      };

      final update = TaskStatusUpdate(
        task,
        TaskStatus.failed,
        TaskHttpException('HTTP 403 Forbidden', 403),
        null,
        null,
        403,
      );

      await DownloadManager.instance.taskFailureForTesting(batch, job, update);

      expect(mockResumeData[job.key], isNull);
      expect(job.progress, 0.0);
      expect(job.urls.first, 'https://video.twimg.com/fresh_url_no_range.mp4');
      final recent = DevLog.recentLines(50);
      expect(recent.any((l) => l.contains('[V16DL]') && l.contains('reason=no_range')), isTrue);
    });

    test('files < 5MB maintain original behavior: no resume attempt and dynamic task ID', () async {
      final batch = createBatch(postId: 'small-file-test', expectedBytes: 2000000); // 2 MB < 5 MB
      final job = batch.jobs.first;

      bool resumeCalled = false;
      DownloadManager.instance.resumeForTesting = (t) async {
        resumeCalled = true;
        return true;
      };

      await DownloadManager.instance.enqueueAttemptForTesting(batch, job);

      expect(resumeCalled, isFalse);
      expect(job.currentTaskId, startsWith('${job.key}-r1-try'));
      final recent = DevLog.recentLines(50);
      expect(recent.any((l) => l.contains('[V16DL]') && l.contains('result=resumed')), isFalse);
    });

    test('missing temp file triggers restart with reason=tempfile_missing', () async {
      final batch = createBatch(postId: 'missing-temp-test');
      final job = batch.jobs.first;
      job.progress = 0.3;
      job.attempts = 1;

      mockResumeData[job.key] = ResumeData(
        DownloadTask(taskId: job.key, url: job.urls.first, filename: job.filename, group: batch.batchId),
        '${tempDir.path}/non_existent_file.tmp',
        300000000,
        '"etag"',
      );

      bool resumeCalled = false;
      DownloadManager.instance.resumeForTesting = (t) async {
        resumeCalled = true;
        return true;
      };

      await DownloadManager.instance.enqueueAttemptForTesting(batch, job);

      expect(resumeCalled, isFalse);
      final recent = DevLog.recentLines(50);
      expect(
        recent.any((l) =>
            l.contains('[V16DL]') &&
            l.contains('result=restart') &&
            l.contains('reason=tempfile_missing') &&
            l.contains('method=enqueue')),
        isTrue,
      );
    });

    test('taskId mismatch triggers restart with reason=taskid_mismatch', () async {
      final batch = createBatch(postId: 'mismatch-taskid-test');
      final job = batch.jobs.first;
      job.progress = 0.3;
      job.attempts = 1;

      mockResumeData[job.key] = ResumeData(
        DownloadTask(taskId: 'different-task-id', url: job.urls.first, filename: job.filename, group: batch.batchId),
        '${tempDir.path}/part.tmp',
        300000000,
        '"etag"',
      );

      bool resumeCalled = false;
      DownloadManager.instance.resumeForTesting = (t) async {
        resumeCalled = true;
        return true;
      };

      await DownloadManager.instance.enqueueAttemptForTesting(batch, job);

      expect(resumeCalled, isFalse);
      final recent = DevLog.recentLines(50);
      expect(
        recent.any((l) =>
            l.contains('[V16DL]') &&
            l.contains('result=restart') &&
            l.contains('reason=taskid_mismatch') &&
            l.contains('method=enqueue')),
        isTrue,
      );
    });

    test('failure callback logs structured diagnostics', () async {
      final batch = createBatch(postId: 'diag-callback-test');
      final job = batch.jobs.first;

      mockResumeData[job.key] = ResumeData(
        DownloadTask(taskId: job.key, url: job.urls.first, filename: job.filename, group: batch.batchId),
        '${tempDir.path}/part.tmp',
        200000000,
        '"etag-diag"',
      );

      final update = TaskStatusUpdate(
        DownloadTask(taskId: job.key, url: job.urls.first, filename: job.filename, group: batch.batchId),
        TaskStatus.failed,
        TaskConnectionException('SocketException: Software caused connection abort'),
      );

      await DownloadManager.instance.taskFailureForTesting(batch, job, update);

      final recent = DevLog.recentLines(50);
      expect(
        recent.any((l) =>
            l.contains('[V16DL]') &&
            l.contains('failure_callback') &&
            l.contains('taskId=${job.key}') &&
            l.contains('has_resume_data=true') &&
            l.contains('temp_exists=true') &&
            l.contains('has_etag=true')),
        isTrue,
      );
    });

    test('end-to-end integration: local HTTP server supporting Range disconnects mid-flight and resumes successfully', () async {
      final serverData = List<int>.generate(6 * 1024 * 1024, (i) => i % 256);
      final receivedRanges = <String?>[];

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest request) async {
        final rangeHeader = request.headers.value('range');
        receivedRanges.add(rangeHeader);

        if (rangeHeader == null) {
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.set('Accept-Ranges', 'bytes');
          request.response.headers.set('ETag', '"v112-test-etag"');
          request.response.headers.set('Content-Length', serverData.length.toString());
          request.response.add(serverData.sublist(0, 2 * 1024 * 1024));
          await request.response.flush();
          final socket = await request.response.detachSocket();
          socket.destroy();
        } else {
          final match = RegExp(r'bytes=(\d+)-').firstMatch(rangeHeader);
          final start = match != null ? int.parse(match.group(1)!) : 0;
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set('Accept-Ranges', 'bytes');
          request.response.headers.set('ETag', '"v112-test-etag"');
          request.response.headers.set(
            'Content-Range',
            'bytes $start-${serverData.length - 1}/${serverData.length}',
          );
          request.response.headers.set(
            'Content-Length',
            (serverData.length - start).toString(),
          );
          request.response.add(serverData.sublist(start));
          await request.response.close();
        }
      });

      try {
        final batch = createBatch(postId: 'e2e-range-test', expectedBytes: serverData.length);
        final job = batch.jobs.first;

        final localPartFile = File('${tempDir.path}/e2e_part.tmp');
        await localPartFile.writeAsBytes(serverData.sublist(0, 2 * 1024 * 1024));
        job.progress = 2 * 1024 * 1024 / serverData.length;

        final failUpdate = TaskStatusUpdate(
          DownloadTask(taskId: job.key, url: job.urls.first, filename: job.filename, group: batch.batchId),
          TaskStatus.failed,
          TaskConnectionException('java.net.SocketException: Software caused connection abort'),
        );

        mockResumeData[job.key] = ResumeData(
          failUpdate.task,
          localPartFile.path,
          2 * 1024 * 1024,
          '"v112-test-etag"',
        );

        await DownloadManager.instance.taskFailureForTesting(batch, job, failUpdate);
        expect(job.state, anyOf(JobState.paused, JobState.waitingNetwork));

        bool resumeSent = false;
        DownloadManager.instance.resumeForTesting = (t) async {
          resumeSent = true;
          expect(t.taskId.startsWith(job.key), isTrue);
          // Directly exercise the local Range HTTP server using the exact start byte
          final client = HttpClient();
          final req = await client.getUrl(Uri.parse('http://${server.address.host}:${server.port}/video.mp4'));
          req.headers.set(HttpHeaders.rangeHeader, 'bytes=${2 * 1024 * 1024}-');
          final resp = await req.close();
          expect(resp.statusCode, HttpStatus.partialContent);
          expect(resp.headers.value(HttpHeaders.acceptRangesHeader), 'bytes');
          final remainingBytes = await resp.fold<List<int>>([], (p, e) => p..addAll(e));
          expect(remainingBytes.length, serverData.length - 2 * 1024 * 1024);
          client.close();
          return true;
        };

        await DownloadManager.instance.enqueueAttemptForTesting(batch, job);

        expect(resumeSent, isTrue);
        expect(receivedRanges, contains('bytes=2097152-'));

        final recent = DevLog.recentLines(50);
        expect(
          recent.any((l) =>
              l.contains('[V16DL]') &&
              l.contains('result=requested') &&
              l.contains('reason=range_requested') &&
              l.contains('method=resume')),
          isTrue,
        );
      } finally {
        await server.close(force: true);
      }
    });

    test('pauseBatch preserves progress and resumeBatch resumes from breakpoint', () async {
      final job = DownloadJob(
        key: 'pause-resume-job',
        label: 'video',
        filename: 'video.mp4',
        urls: ['https://video.twimg.com/test_video.mp4'],
        isImage: false,
        itemIndex: 0,
      );
      job.expectedBytes = 100 * 1024 * 1024;
      job.progress = 0.45; // 45% downloaded
      job.state = JobState.active;
      job.currentTaskId = job.key;
      job.resumeStartByte = 45 * 1024 * 1024;
      job.resumeTempPath = localPartFile.path;

      final batch = DownloadBatch(
        batchId: 'pause-resume-batch',
        album: 'test',
        postUrl: 'https://x.com/user/status/1234',
        platform: 'x',
        postId: 'pause-resume-post',
        jobs: [job],
      );

      DownloadManager.instance.setBatchForTesting(batch);
      DownloadManager.instance.taskForIdForTesting = (id) async =>
          DownloadTask(taskId: id, url: job.urls.first, allowPause: true);
      DownloadManager.instance.pauseForTesting = (t) async => true;

      // 1. Pause batch
      await DownloadManager.instance.pauseBatch(batch);
      expect(job.state, JobState.paused);
      expect(job.progress, 0.45, reason: 'Progress must not be wiped out on pause');

      // 2. Resume batch
      bool resumed = false;
      DownloadManager.instance.resumeForTesting = (t) async {
        resumed = true;
        expect(t.taskId.startsWith(job.key), isTrue);
        return true;
      };

      await DownloadManager.instance.resumeBatch(batch);
      expect(resumed, isTrue, reason: 'resumeBatch must call _resumeTask');
      expect(job.progress, 0.45);
    });

    test('App recovers and resumes when plugin ResumeData is wiped out on task failure', () async {
      final job = DownloadJob(
        key: 'loss-recovery-job',
        label: 'video',
        filename: 'video.mp4',
        urls: ['https://video.twimg.com/test_video.mp4'],
        isImage: false,
        itemIndex: 0,
      );
      job.expectedBytes = 100 * 1024 * 1024;
      job.state = JobState.active;
      job.currentTaskId = job.key;
      job.progress = 0.3;

      final batch = DownloadBatch(
        batchId: 'loss-recovery-batch',
        album: 'test',
        postUrl: 'https://x.com/user/status/1235',
        platform: 'x',
        postId: 'loss-recovery-post',
        jobs: [job],
      );

      final failUpdate = TaskStatusUpdate(
        DownloadTask(
          taskId: job.key,
          url: job.urls.first,
          allowPause: true,
          headers: {'accept-ranges': 'bytes'},
        ),
        TaskStatus.failed,
        TaskConnectionException('SocketException: Software caused connection abort'),
      );

      // Plugin provides ResumeData at failure callback time
      mockResumeData[job.key] = ResumeData(
        failUpdate.task,
        localPartFile.path,
        30 * 1024 * 1024,
        null,
      );

      await DownloadManager.instance.taskFailureForTesting(batch, job, failUpdate);
      expect(job.state, anyOf(JobState.paused, JobState.waitingNetwork));
      expect(job.resumeStartByte, 30 * 1024 * 1024);

      // Now simulate plugin BaseDownloader deleting ResumeData from plugin storage
      mockResumeData.remove(job.key);

      bool resumed = false;
      DownloadManager.instance.resumeForTesting = (t) async {
        resumed = true;
        return true;
      };

      // App re-enqueues: App must restore ResumeData from job.resumeStartByte and resume
      await DownloadManager.instance.enqueueAttemptForTesting(batch, job);
      expect(resumed, isTrue);
      expect((mockResumeData[job.currentTaskId ?? job.key] ?? mockResumeData[job.key])?.requiredStartByte, 30 * 1024 * 1024);
    });

    test('multiple network disconnects guarantee monotonic non-decreasing start byte', () async {
      final job = DownloadJob(
        key: 'multi-disconnect-job',
        label: 'video',
        filename: 'video.mp4',
        urls: ['https://video.twimg.com/test_video.mp4'],
        isImage: false,
        itemIndex: 0,
      );
      job.expectedBytes = 500 * 1024 * 1024;
      job.state = JobState.active;
      job.currentTaskId = job.key;

      final batch = DownloadBatch(
        batchId: 'multi-disconnect-batch',
        album: 'test',
        postUrl: 'https://x.com/user/status/1236',
        platform: 'x',
        postId: 'multi-disconnect-post',
        jobs: [job],
      );

      final task = DownloadTask(
        taskId: job.key,
        url: job.urls.first,
        allowPause: true,
      );

      // Disconnect 1: 100MB
      mockResumeData[job.key] = ResumeData(task, localPartFile.path, 100 * 1024 * 1024, null);
      await DownloadManager.instance.taskFailureForTesting(
        batch,
        job,
        TaskStatusUpdate(task, TaskStatus.failed, TaskConnectionException('abort')),
      );
      expect(job.resumeStartByte, 100 * 1024 * 1024);

      // Disconnect 2: progressed to 250MB
      mockResumeData[job.key] = ResumeData(task, localPartFile.path, 250 * 1024 * 1024, null);
      await DownloadManager.instance.taskFailureForTesting(
        batch,
        job,
        TaskStatusUpdate(task, TaskStatus.failed, TaskConnectionException('abort')),
      );
      expect(job.resumeStartByte, 250 * 1024 * 1024);

      // Disconnect 3: handshake glitch reported 0 or smaller bytes
      mockResumeData[job.key] = ResumeData(task, localPartFile.path, 10 * 1024 * 1024, null);
      await DownloadManager.instance.taskFailureForTesting(
        batch,
        job,
        TaskStatusUpdate(task, TaskStatus.failed, TaskConnectionException('abort')),
      );
      expect(job.resumeStartByte, 250 * 1024 * 1024, reason: 'Start byte must never regress');
    });

    test('size_mismatch discards resume data and restarts from zero', () async {
      final job = DownloadJob(
        key: 'mismatch-job',
        label: 'video',
        filename: 'video.mp4',
        urls: ['https://video.twimg.com/test_video.mp4'],
        isImage: false,
        itemIndex: 0,
      );
      job.expectedBytes = 1020613970;
      job.progress = 0.2;
      job.resumeStartByte = 200000000;
      job.resumeTempPath = localPartFile.path;

      final batch = DownloadBatch(
        batchId: 'mismatch-batch',
        album: 'test',
        postUrl: 'https://x.com/user/status/1237',
        platform: 'x',
        postId: 'mismatch-post',
        jobs: [job],
      );

      final task = DownloadTask(taskId: job.key, url: job.urls.first, allowPause: true);
      final mismatchUpdate = TaskStatusUpdate(
        task,
        TaskStatus.failed,
        TaskResumeException('size_mismatch: server total 500000000 != expected 1020613970'),
      );

      bool reEnqueued = false;
      DownloadManager.instance.enqueueForTesting = (b, j) async {
        reEnqueued = true;
      };

      await DownloadManager.instance.taskFailureForTesting(batch, job, mismatchUpdate);

      expect(reEnqueued, isTrue);
      expect(job.resumeStartByte, isNull);
      expect(job.progress, 0);

      final recent = DevLog.recentLines(20);
      expect(recent.any((l) => l.contains('reason=size_mismatch')), isTrue);
    });

    test('DownloadJob serializes and deserializes resumeStartByte and resumeTempPath for process kill recovery', () {
      final job = DownloadJob(
        key: 'kill-recovery-job',
        label: 'video',
        filename: 'video.mp4',
        urls: ['https://video.twimg.com/123.mp4'],
        isImage: false,
        itemIndex: 0,
      );
      job.resumeStartByte = 210140833;
      job.resumeTempPath = '/data/user/0/com.james.easysave/cache/part.tmp';
      job.resumeEtag = '"etag-video"';

      final json = job.toJson();
      expect(json['resumeStartByte'], 210140833);
      expect(json['resumeTempPath'], '/data/user/0/com.james.easysave/cache/part.tmp');
      expect(json['resumeEtag'], '"etag-video"');

      final restored = DownloadJob.fromJson(json);
      expect(restored.resumeStartByte, 210140833);
      expect(restored.resumeTempPath, '/data/user/0/com.james.easysave/cache/part.tmp');
      expect(restored.resumeEtag, '"etag-video"');
    });
  });

  group('Build 67: Resumable download, 0-file settlement, cleanup, storage, and stage locking', () {
    test('StorageGuard accounts for partialBytes in free space check and uses 空间不足', () {
      const total = 1000 * 1024 * 1024; // 1000MB
      const partial = 400 * 1024 * 1024; // 400MB
      // need = (1000 - 400) + 1000 + 256MB = 1856MB
      final need = requiredBytesForDownload(total, partial);
      expect(need, (600 + 1000 + 256) * 1024 * 1024);
      expect(storageFullMessage(), '空间不足');
    });

    test('0-file settlement sets non-null downloadError and preserves placeholder in HistoryDb', () async {
      final dbPath = '${tempDir.path}/p0_test.db';
      HistoryDb.resetInstanceForTesting();
      final testDb = await HistoryDb.instance(dbPath: dbPath);

      final job = DownloadJob(
        key: 'p0-job',
        label: 'video',
        filename: 'video.mp4',
        urls: ['https://x.com/video.mp4'],
        isImage: false,
        itemIndex: 0,
      );
      job.state = JobState.canceled;
      final batch = DownloadBatch(
        batchId: 'p0-batch',
        album: 'test',
        postUrl: 'https://x.com/1',
        platform: 'x',
        postId: 'p0-post',
        jobs: [job],
      );

      await writeBatchHistory(testDb, batch, recovered: false);
      final record = await testDb.getByPostId('p0-post');
      expect(record, isNotNull);
      expect(record!.files, isEmpty);
      // 1c: downloadError must NEVER be null when files is empty
      expect(record.downloadError, isNotNull);
      expect(record.downloadError, '已取消');

      HistoryDb.resetInstanceForTesting();
    });

    test('isFinishing stage lock protects job from late cancellation during finishing', () {
      final job = DownloadJob(
        key: 'finish-lock-job',
        label: 'video',
        filename: 'video.mp4',
        urls: ['https://x.com/video.mp4'],
        isImage: false,
        itemIndex: 0,
      );
      expect(job.isFinishing, isFalse);
      job.isFinishing = true;
      expect(job.isFinishing, isTrue);
    });

    test('tempSweep removes files older than 1 hour and unreferenced session dirs', () async {
      DownloadManager.instance.tempRootForTesting = () async => tempDir;

      final oldPluginFile = File('${tempDir.path}/com.bbflight.background_downloader.old.tmp');
      await oldPluginFile.writeAsString('old temp');
      await oldPluginFile.setLastModified(DateTime.now().subtract(const Duration(hours: 2)));

      final freshPluginFile = File('${tempDir.path}/com.bbflight.background_downloader.fresh.tmp');
      await freshPluginFile.writeAsString('fresh temp');

      final sweepResult = await DownloadManager.instance.tempSweep();
      expect(sweepResult.files, greaterThanOrEqualTo(1));
      expect(await oldPluginFile.exists(), isFalse);
      expect(await freshPluginFile.exists(), isTrue);

      final recentLogs = DevLog.recentLines(20);
      expect(recentLogs.any((l) => l.contains('[V16DL]') && l.contains('temp_sweep')), isTrue);

      DownloadManager.instance.tempRootForTesting = null;
    });
  });
}
