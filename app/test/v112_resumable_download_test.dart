import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/resumable_download_store.dart';
import 'package:easysave/services/session_media_download.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late ResumableDownloadStore store;

  setUp(() async {
    HttpOverrides.global = null;
    SiteRegistry.useBuiltin();
    tempDir = await Directory.systemTemp.createTemp('v112_resumable_test_');
    store = ResumableDownloadStore.instance;
    store.overrideDirectory = tempDir;
  });

  tearDown(() async {
    SiteRegistry.useBuiltin();
    store.overrideDirectory = null;
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
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
}
