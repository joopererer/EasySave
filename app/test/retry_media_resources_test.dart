import 'dart:convert';

import 'package:easysave/core/media_request.dart';
import 'package:easysave/core/models.dart';
import 'package:easysave/services/download_claims.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/media_request_policy.dart';
import 'package:easysave/services/parse_service.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common/src/factory.dart' show SqfliteDatabaseFactory;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _RetryMemoryDatabaseFactory implements SqfliteDatabaseFactory {
  @override
  Future<Database> openDatabase(String path, {OpenDatabaseOptions? options}) =>
      databaseFactoryFfi.openDatabase(inMemoryDatabasePath, options: options);
  @override
  Future<String> getDatabasesPath() async => '/isolated-retry-resources';
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected DB operation ${invocation.memberName}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final manager = DownloadManager.instance;
  late ParsedPost fresh;
  late List<DownloadJob> enqueued;
  var reparses = 0;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = _RetryMemoryDatabaseFactory();
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    SiteRegistry.useBuiltin();
    manager.clearBatchesForTesting();
    HistoryDb.resetInstanceForTesting();
    await HistoryDb.instance();
    enqueued = [];
    reparses = 0;
    manager.reparseForTesting = (url) async {
      expect(url, 'https://www.xiaohongshu.com/explore/retry_post');
      reparses++;
      return ParseOutcome(data: fresh, rawImages: const []);
    };
    manager.enqueueForTesting = (_, job) async {
      // Check the actual persisted job handed to the enqueue boundary. Merely
      // refreshing job.urls must not leave the old authorization alongside it.
      expect(job.resources.map((r) => r.url).toList(), job.urls);
      expect(job.resources, isNotEmpty);
      final policy = MediaRequestPolicy(SiteRegistry.current.byId('xhs')!,
          readCookie: (_) async => throw StateError('XHS CDN must not read a jar'));
      for (final resource in job.resources) {
        expect(resource.request.cookieDomains, isEmpty);
        final authorized = await policy.authorize(resource);
        expect(authorized.wireHeaders.containsKey('Cookie'), isFalse);
      }
      enqueued.add(job);
    };
  });
  tearDown(() async {
    for (final batch in await manager.liveBatches()) {
      await DownloadClaims.release(batch.batchId);
    }
    manager.reparseForTesting = null;
    manager.enqueueForTesting = null;
    manager.clearBatchesForTesting();
    HistoryDb.resetInstanceForTesting();
    SiteRegistry.useBuiltin();
  });

  ParsedPost post(List<MediaItem> items) => ParsedPost(
      platform: 'xhs', id: 'retry_post',
      url: 'https://www.xiaohongshu.com/explore/retry_post',
      author: PostAuthor(), items: items);

  DownloadJob oldJob(String key, String url, {required bool image,
      int itemIndex = 1, bool live = false}) => DownloadJob(
    key: key, label: 'fixture', filename: image ? '$key.jpg' : '$key.mp4',
    urls: [url], isImage: image, itemIndex: itemIndex, isLivePhoto: live,
    resources: [MediaRequestResource(
      role: image ? MediaResourceRole.image
          : live ? MediaResourceRole.motion : MediaResourceRole.video,
      url: url,
      request: MediaRequestRequirements(
        headers: const {'Referer': 'https://www.xiaohongshu.com/'},
        cookieDomains: const ['xiaohongshu.com', 'rednote.com'],
        transport: MediaTransport.background, resumable: true,
      ),
    )],
  )..state = JobState.failed;

  DownloadBatch stored(List<DownloadJob> jobs) {
    final batch = DownloadBatch(batchId: 'retry-resources', album: 'EasySave',
      platform: 'xhs', postId: 'retry_post', postUrl: fresh.url, jobs: jobs);
    manager.setBatchForTesting(batch);
    return batch;
  }

  test('retryBatch replaces build25 URLs and cookie scopes without changing saved jobs', () async {
    fresh = post([
      MediaItem(type: 'image', url: 'https://ci.xiaohongshu.com/fresh.jpg'),
      MediaItem(type: 'image', url: 'https://ci.xiaohongshu.com/second.jpg'),
    ]);
    final failed = oldJob('retry-resources-failed',
        'https://ci.xiaohongshu.com/expired.jpg', image: true);
    final saved = oldJob('retry-resources-saved',
        'https://ci.xiaohongshu.com/already-saved.jpg', image: true, itemIndex: 2)
      ..state = JobState.done
      ..saved = true
      ..assetId = 'existing-asset'
      ..mediaId = 'existing-media';
    final savedBefore = jsonEncode(saved.toJson());
    final batch = stored([failed, saved]);
    await manager.retryBatch(batch);
    expect(reparses, 1);
    expect(enqueued, [failed]);
    expect(failed.urls, ['https://ci.xiaohongshu.com/fresh.jpg']);
    expect(failed.resources.single.url, failed.urls.single);
    expect(failed.resources.single.request.cookieDomains, isEmpty);
    expect(jsonEncode(saved.toJson()), savedBefore);
  });

  test('retrying a Live still selects only its image and image fallback resources', () async {
    fresh = post([MediaItem(type: 'live',
      url: 'https://ci.xiaohongshu.com/new-still.jpg',
      fallbacks: ['https://sns-webpic-qc.xhscdn.com/new-still.jpg'],
      videoUrl: 'https://sns-video-bd.xhscdn.com/new-motion.mp4')]);
    final still = oldJob('retry-resources-still',
        'https://ci.xiaohongshu.com/old-still.jpg', image: true, live: true);
    final batch = stored([still]);
    await manager.retryJob(batch, still);
    expect(enqueued, [still]);
    expect(still.urls.toSet(), {
      'https://ci.xiaohongshu.com/new-still.jpg',
      'https://sns-webpic-qc.xhscdn.com/new-still.jpg',
    });
    expect(still.resources.every((r) => r.role == MediaResourceRole.image ||
        r.role == MediaResourceRole.fallback && r.fallbackFor == MediaResourceRole.image), isTrue);
  });

  test('retrying a Live motion selects its motion resource without still-image candidates', () async {
    fresh = post([MediaItem(type: 'live',
      url: 'https://ci.xiaohongshu.com/new-still.jpg',
      fallbacks: ['https://sns-webpic-qc.xhscdn.com/new-still.jpg'],
      videoUrl: 'https://sns-video-bd.xhscdn.com/new-motion.mp4')]);
    final motion = oldJob('retry-resources-motion',
        'https://sns-video-bd.xhscdn.com/old-motion.mp4', image: false, live: true);
    final batch = stored([motion]);
    await manager.retryJob(batch, motion);
    expect(enqueued, [motion]);
    expect(motion.urls, ['https://sns-video-bd.xhscdn.com/new-motion.mp4']);
    expect(motion.resources.single.role, MediaResourceRole.motion);
  });

  test('retrying video uses fresh video authorization rather than its poster', () async {
    fresh = post([MediaItem(type: 'video',
      url: 'https://ci.xiaohongshu.com/fresh-poster.jpg',
      videoUrl: 'https://sns-video-bd.xhscdn.com/fresh-video.mp4')]);
    final video = oldJob('retry-resources-video',
        'https://sns-video-bd.xhscdn.com/old-video.mp4', image: false);
    await manager.retryJob(stored([video]), video);
    expect(enqueued, [video]);
    expect(video.urls, ['https://sns-video-bd.xhscdn.com/fresh-video.mp4']);
    expect(video.resources.single.role, MediaResourceRole.video);
  });

  test('enqueue failure restores failed state so a second user retry can proceed', () async {
    fresh = post([MediaItem(type: 'image',
        url: 'https://ci.xiaohongshu.com/retryable.jpg')]);
    final job = oldJob('retry-resources-enqueue',
        'https://ci.xiaohongshu.com/old.jpg', image: true);
    final batch = stored([job]);
    var attempts = 0;
    manager.enqueueForTesting = (_, retried) async {
      attempts++;
      if (attempts == 1) throw StateError('synthetic enqueue failure');
      expect(retried.resources.map((r) => r.url).toList(), retried.urls);
      expect(retried.resources.single.request.cookieDomains, isEmpty);
      enqueued.add(retried);
    };
    await expectLater(manager.retryJob(batch, job), completes);
    expect(job.state, JobState.failed);
    expect(job.error, isNotNull);
    await manager.retryJob(batch, job);
    expect(attempts, 2);
    expect(reparses, 2);
    expect(enqueued, [job]);
    expect(job.state, JobState.queued);
  });
}
