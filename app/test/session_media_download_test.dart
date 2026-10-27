import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:easysave/core/dev_log.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/session_media_download.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Real loopback HTTP exercises streaming, stalled connections and cleanup.
  late HttpServer server;
  late Directory directory;
  late File output;
  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    directory = await Directory.systemTemp.createTemp('session_download_test');
    output = File('${directory.path}/video.mp4');
  });
  tearDown(() async {
    await server.close(force: true);
    await directory.delete(recursive: true);
  });
  String url([String query = '']) => 'http://127.0.0.1:${server.port}/video$query';
  const secret = 'DO_NOT_PERSIST_COOKIE_VALUE';

  test('streams Cookie and Referer, reports progress, stores only media bytes', () async {
    server.listen((request) async {
      expect(request.headers.value('cookie'), 'sessionid=$secret');
      expect(request.headers.value('referer'), 'https://www.tiktok.com/');
      request.response.contentLength = 6;
      request.response.add([1, 2, 3]);
      await request.response.flush();
      request.response.add([4, 5, 6]);
      await request.response.close();
    });
    final progress = <double>[];
    await SessionMediaDownload().download(url: url(), destination: output,
      readCookie: () async => 'sessionid=$secret', onProgress: progress.add);
    expect(await output.readAsBytes(), [1, 2, 3, 4, 5, 6]);
    expect(progress.last, 1);
    expect(directory.listSync().length, 1);
  });

  test('403 has fixed expiry diagnostic, no response or Cookie values', () async {
    var requests = 0;
    server.listen((request) async {
      requests++;
      request.response.statusCode = 403;
      request.response.headers.set('set-cookie', 'sessionid=$secret');
      request.response.write(secret);
      await request.response.close();
    });
    Object? failure;
    try {
      await SessionMediaDownload().download(url: url(), destination: output,
        readCookie: () async => 'sessionid=$secret', onProgress: (_) {});
    } catch (e) { failure = e; }
    expect(failure.toString(), expiredMediaMessage);
    expect(DevLog.scrub('$failure'), isNot(contains(secret)));
    expect(requests, 1);
    expect(await output.exists(), false);
  });

  test('expired URL fails before reading Cookie or issuing HTTP', () async {
    var reads = 0;
    await expectLater(SessionMediaDownload().download(url: url('?x-expires=1'),
      destination: output, readCookie: () async { reads++; return secret; },
      onProgress: (_) {}), throwsA(isA<SessionDownloadException>()));
    expect(reads, 0);
    expect(await output.exists(), false);
  });

  test('both expiry keys and duplicated parameters are checked', () {
    final now = DateTime.fromMillisecondsSinceEpoch(2000000);
    expect(mediaUrlExpired('https://cdn/v?expire=2000', now: now), true);
    expect(mediaUrlExpired('https://cdn/v?x-expires=3000&x-expires=1000', now: now), true);
    expect(mediaUrlExpired('https://cdn/v?expire=3000', now: now), false);
  });

  test('cancel stalled stream waits for partial file removal', () async {
    server.listen((request) async {
      request.response.contentLength = 1000;
      request.response.bufferOutput = false;
      request.response.add([1, 2, 3]);
      await request.response.flush();
    });
    final started = Completer<void>();
    final transfer = SessionMediaDownload();
    final result = transfer.download(url: url(), destination: output,
      readCookie: () async => secret,
      onProgress: (_) { if (!started.isCompleted) started.complete(); });
    final assertion = expectLater(result, throwsA(isA<SessionDownloadCanceled>()));
    await started.future;
    expect(await output.exists(), true);
    await transfer.cancel();
    await assertion;
    expect(await output.exists(), false);
  });

  test('Cookie provider errors cannot leak through diagnostic or log messages', () async {
    Object? failure;
    try {
      await SessionMediaDownload().download(url: url(), destination: output,
        readCookie: () async => throw StateError(secret), onProgress: (_) {});
    } catch (e) { failure = e; }
    expect(failure, isA<SessionDownloadException>());
    expect('$failure', isNot(contains(secret)));
    expect(DevLog.scrub('Cookie: arbitrary=$secret; other=$secret'), isNot(contains(secret)));
    expect(await output.exists(), false);
  });

  test('redirect does not forward Cookie and does not retry', () async {
    var requests = 0;
    server.listen((request) async {
      requests++;
      request.response.statusCode = 302;
      request.response.headers.set('location', url('/redirect'));
      await request.response.close();
    });
    await expectLater(SessionMediaDownload().download(url: url(), destination: output,
      readCookie: () async => secret, onProgress: (_) {}),
      throwsA(isA<SessionDownloadException>()));
    expect(requests, 1);
  });

  test('persisted active and paused videos recover as needs-reparse, images do not', () {
    for (final state in [JobState.active, JobState.queued, JobState.paused]) {
      final video = DownloadJob(key: 'v', label: 'video', filename: 'video.mp4',
          urls: ['https://cdn/video'], isImage: false, itemIndex: 1)..state = state;
      final image = DownloadJob(key: 'i', label: 'image', filename: 'image.jpg',
          urls: ['https://cdn/image'], isImage: true, itemIndex: 2);
      final batch = DownloadBatch(batchId: 'batch', album: 'album', postUrl: 'https://www.tiktok.com/@/video/1',
          platform: 'tiktok', postId: '1', jobs: [video, image]);
      final encoded = jsonEncode(batch.toJson());
      expect(encoded.toLowerCase(), isNot(contains('cookie')));
      expect(encoded, isNot(contains(secret)));
      final restored = DownloadBatch.fromJson((jsonDecode(encoded) as Map).cast<String, Object?>());
      expect(recoverSessionJob(restored, restored.jobs.first), true);
      expect(restored.jobs.first.error, interruptedMediaMessage);
      expect(restored.jobs.first.currentTaskId, null);
      expect(recoverSessionJob(restored, restored.jobs.last), false);
    }
  });
}
