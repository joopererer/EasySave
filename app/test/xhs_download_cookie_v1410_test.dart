import 'dart:convert';

import 'package:background_downloader/background_downloader.dart' hide Database;
import 'package:easysave/core/models.dart';
import 'package:easysave/services/authorized_media_http.dart';
import 'package:easysave/services/download_claims.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/media_request_policy.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common/src/factory.dart' show SqfliteDatabaseFactory;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Simulate a logged-in WebView without consulting a device or real account.
class _SyntheticCookiesPlatform extends InAppWebViewPlatform {
  final lookups = <Uri>[];

  @override
  PlatformCookieManager createPlatformCookieManager(
    PlatformCookieManagerCreationParams params,
  ) => _SyntheticCookies(params, lookups);
}

class _SyntheticCookies extends PlatformCookieManager {
  _SyntheticCookies(super.params, this.lookups) : super.implementation();
  final List<Uri> lookups;

  @override
  Future<List<Cookie>> getCookies({
    required WebUri url,
    PlatformInAppWebViewController? iosBelow11WebViewController,
    PlatformInAppWebViewController? webViewController,
  }) async {
    final uri = Uri.parse(url.toString());
    lookups.add(uri);
    return [
      Cookie(name: 'web_session', value: 'synthetic_hop_${lookups.length}'),
    ];
  }
}

/// The real downloader is used through its native enqueue boundary. Its backing
/// storage is isolated in memory so tests cannot inspect an existing task DB.
class _MemoryStorage implements PersistentStorage {
  final records = <String, TaskRecord>{};
  final paused = <String, Task>{};
  final resumed = <String, ResumeData>{};
  @override
  (String, int) get currentDatabaseVersion => ('test', 1);
  @override
  Future<(String, int)> get storedDatabaseVersion async => ('test', 1);
  @override
  Future<void> initialize() async {}
  @override
  Future<void> storeTaskRecord(TaskRecord value) async =>
      records[value.taskId] = value;
  @override
  Future<TaskRecord?> retrieveTaskRecord(String id) async => records[id];
  @override
  Future<List<TaskRecord>> retrieveAllTaskRecords() async =>
      records.values.toList();
  @override
  Future<void> removeTaskRecord(String? id) async {
    id == null ? records.clear() : records.remove(id);
  }

  @override
  Future<void> storePausedTask(Task value) async =>
      paused[value.taskId] = value;
  @override
  Future<Task?> retrievePausedTask(String id) async => paused[id];
  @override
  Future<List<Task>> retrieveAllPausedTasks() async => paused.values.toList();
  @override
  Future<void> removePausedTask(String? id) async {
    id == null ? paused.clear() : paused.remove(id);
  }

  @override
  Future<void> storeResumeData(ResumeData value) async =>
      resumed[value.taskId] = value;
  @override
  Future<ResumeData?> retrieveResumeData(String id) async => resumed[id];
  @override
  Future<List<ResumeData>> retrieveAllResumeData() async =>
      resumed.values.toList();
  @override
  Future<void> removeResumeData(String? id) async {
    id == null ? resumed.clear() : resumed.remove(id);
  }
}

class _MemoryDatabaseFactory implements SqfliteDatabaseFactory {
  @override
  Future<Database> openDatabase(String path, {OpenDatabaseOptions? options}) =>
      databaseFactoryFfi.openDatabase(inMemoryDatabasePath, options: options);
  @override
  Future<String> getDatabasesPath() async => '/isolated-cookie-test';
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Unexpected DB operation ${invocation.memberName}',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final manager = DownloadManager.instance;
  final cookies = _SyntheticCookiesPlatform();
  final enqueued = <Map<String, dynamic>>[];
  final originalWebView = InAppWebViewPlatform.instance;
  const downloaderChannel = MethodChannel('com.bbflight.background_downloader');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUpAll(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    InAppWebViewPlatform.instance = cookies;
    sqfliteFfiInit();
    databaseFactory = _MemoryDatabaseFactory();
    messenger.setMockMethodCallHandler(downloaderChannel, (call) async {
      if (call.method == 'enqueue') {
        final args = call.arguments as List;
        enqueued.add(jsonDecode(args.first as String) as Map<String, dynamic>);
        return true;
      }
      return null;
    });
    await FileDownloader(persistentStorage: _MemoryStorage()).ready;
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    SiteRegistry.useBuiltin();
    manager.clearBatchesForTesting();
    manager.prepareStartForTesting = () async {};
    manager.enqueueForTesting = null;
    HistoryDb.resetInstanceForTesting();
    await HistoryDb.instance();
    enqueued.clear();
    cookies.lookups.clear();
  });
  tearDown(() async {
    for (final batch in await manager.liveBatches()) {
      await DownloadClaims.release(batch.batchId);
    }
    manager.clearBatchesForTesting();
    manager.prepareStartForTesting = null;
    HistoryDb.resetInstanceForTesting();
    SiteRegistry.useBuiltin();
  });
  tearDownAll(() {
    messenger.setMockMethodCallHandler(downloaderChannel, null);
    debugDefaultTargetPlatformOverride = null;
    if (originalWebView != null)
      InAppWebViewPlatform.instance = originalWebView;
  });

  for (final host in ['ci.xiaohongshu.com', 'sns-webpic-qc.xhscdn.com']) {
    test(
      'startBatch enqueues $host without an inherited login cookie',
      () async {
        final post = ParsedPost(
          platform: 'xhs',
          id: 'cookie_test',
          url: 'https://www.xiaohongshu.com/explore/cookie_test',
          author: PostAuthor(),
          items: [MediaItem(type: 'image', url: 'https://$host/fixture.jpg')],
        );
        final batch = await manager.startBatch(
          post,
          [0],
          album: 'EasySave',
          nameFor: (_, _, _) => 'fixture',
        );
        expect(batch.jobs.single.state, JobState.queued);
        expect(enqueued, hasLength(1));
        expect(enqueued.single['url'], post.items.single.url);
        final headers = enqueued.single['headers'] as Map;
        expect(
          headers.keys.map((key) => key.toString().toLowerCase()),
          isNot(contains('cookie')),
        );
        expect(headers['Referer'], 'https://www.xiaohongshu.com/');
        expect(cookies.lookups, isEmpty);
      },
    );
  }

  test(
    'XHS ci to sns to ci redirects remain cookie-free with a logged-in jar',
    () async {
      final policy = MediaRequestPolicy(SiteRegistry.current.byId('xhs')!);
      final resource = policy
          .resourcesFor(
            MediaItem(
              type: 'image',
              url: 'https://ci.xiaohongshu.com/fixture.jpg',
            ),
          )
          .single;
      final seen = <http.Request>[];
      final client = MockClient((request) async {
        seen.add(request);
        expect(request.followRedirects, isFalse);
        if (seen.length == 1) {
          return http.Response(
            '',
            302,
            headers: {
              'location': 'https://sns-webpic-qc.xhscdn.com/fixture.jpg',
            },
          );
        }
        if (seen.length == 2) {
          return http.Response(
            '',
            302,
            headers: {'location': 'https://ci.xiaohongshu.com/final.jpg'},
          );
        }
        return http.Response('fixture-image-bytes', 200);
      });
      addTearDown(client.close);
      final response = await sendAuthorizedMediaGet(client, policy, resource);
      expect(await response.stream.bytesToString(), 'fixture-image-bytes');
      expect(seen, hasLength(3));
      for (final request in seen) {
        expect(request.headers.containsKey('cookie'), isFalse);
      }
      expect(cookies.lookups, isEmpty);
    },
  );

  test(
    'TikTok video refreshes scoped cookies and strips them on CDN redirects',
    () async {
      final policy = MediaRequestPolicy(SiteRegistry.current.byId('tiktok')!);
      final resource = policy
          .resourcesFor(
            MediaItem(
              type: 'video',
              url: 'https://v16-webapp-prime.tiktok.com/first.mp4',
            ),
          )
          .single;
      final seen = <http.Request>[];
      final client = MockClient((request) async {
        seen.add(request);
        expect(request.followRedirects, isFalse);
        final next = switch (seen.length) {
          1 => 'https://v19-webapp-prime.tiktok.com/second.mp4',
          2 => 'https://p16-common-sign.tiktokcdn-eu.com/cdn.mp4',
          3 => 'https://v16-webapp-prime.tiktok.com/final.mp4',
          _ => null,
        };
        return next == null
            ? http.Response('fixture-video-bytes', 200)
            : http.Response('', 302, headers: {'location': next});
      });
      addTearDown(client.close);
      final response = await sendAuthorizedMediaGet(client, policy, resource);
      expect(await response.stream.bytesToString(), 'fixture-video-bytes');
      expect(seen.map((request) => request.headers['cookie']), [
        'web_session=synthetic_hop_1',
        'web_session=synthetic_hop_2',
        null,
        'web_session=synthetic_hop_3',
      ]);
      expect(cookies.lookups.map((uri) => uri.path), [
        '/first.mp4',
        '/second.mp4',
        '/final.mp4',
      ]);
    },
  );
}
