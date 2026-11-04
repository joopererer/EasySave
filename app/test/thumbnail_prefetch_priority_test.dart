import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:easysave/core/models.dart';
import 'package:easysave/services/media_request_policy.dart';
import 'package:easysave/services/shared_preview_cache.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
  );
  const channel = MethodChannel('test/build23-prefetch-priority');
  final visible = <String, int>{};
  final files = <String, String>{};
  var promoted = false;
  final policy = MediaRequestPolicy(SiteRegistry.current.byId('instagram')!);
  final resource = policy
      .resourcesFor(
        MediaItem(
          type: 'image',
          url: 'https://scontent.cdninstagram.com/synthetic.png',
        ),
      )
      .first;
  setUp(() async {
    visible.clear();
    files.clear();
    promoted = false;
    await Directory('build/build23-prefetch-priority').create(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final args = (call.arguments as Map?) ?? {};
          final key = args['key'] as String?;
          switch (call.method) {
            case 'thumbnailVisibleBegin':
              visible[key!] = (visible[key] ?? 0) + 1;
              return null;
            case 'thumbnailVisibleEnd':
              final count = (visible[key] ?? 1) - 1;
              if (count <= 0) {
                visible.remove(key);
              } else {
                visible[key!] = count;
              }
              return null;
            case 'thumbnailPrefetchIdle':
              return visible.isEmpty || visible.containsKey(key);
            case 'thumbnailVisible':
              if (visible.containsKey(key)) promoted = true;
              return visible.containsKey(key);
            case 'thumbnailPrefetchAllowed':
              return true;
            case 'thumbnailAcquire':
              return true;
            case 'thumbnailRead':
              return files[key];
            case 'thumbnailWrite':
              final file = File('build/build23-prefetch-priority/$key');
              await file.writeAsBytes((args['bytes'] as List).cast<int>());
              files[key!] = file.path;
              return file.path;
          }
          return null;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  test(
    'other engine visible work pauses then resumes background prefetch',
    () async {
      final foreground = Completer<http.Response>();
      final foregroundStarted = Completer<void>();
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        if (request.url.path == '/synthetic.png') {
          foregroundStarted.complete();
          return foreground.future;
        }
        return http.Response.bytes(png, 200);
      });
      final app = SharedThumbnailCache(client: client, channel: channel);
      final overlay = SharedThumbnailCache(
        client: client,
        channel: channel,
        prefetchInterval: Duration.zero,
      );
      final viewing = app.load(
        policy,
        resource,
        identity: 'instagram:viewing:0:thumb',
      );
      await foregroundStarted.future;
      final post = ParsedPost(
        platform: 'instagram',
        id: 'speculative',
        url: 'https://www.instagram.com/p/speculative/',
        author: PostAuthor(),
        items: [
          MediaItem(
            type: 'image',
            url: 'https://scontent.cdninstagram.com/speculative.png',
          ),
        ],
      );
      final prefetching = overlay.prefetch(post);
      await Future<void>.delayed(const Duration(milliseconds: 75));
      expect(requests, 1);
      foreground.complete(http.Response.bytes(png, 200));
      await viewing;
      await prefetching;
      expect(requests, 2);
      expect(visible, isEmpty);
      client.close();
    },
  );

  test(
    'visible subscriber promotes a waiting same-key prefetch without deadlock',
    () async {
      final foreground = Completer<http.Response>();
      final foregroundStarted = Completer<void>();
      final promotedStarted = Completer<void>();
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        if (request.url.path == '/synthetic.png') {
          foregroundStarted.complete();
          return foreground.future;
        }
        promotedStarted.complete();
        return http.Response.bytes(png, 200);
      });
      final app = SharedThumbnailCache(client: client, channel: channel);
      final overlay = SharedThumbnailCache(client: client, channel: channel);
      final viewing = app.load(
        policy,
        resource,
        identity: 'instagram:blocking:0:thumb',
      );
      await foregroundStarted.future;
      final other = resource.atUrl(
        'https://scontent.cdninstagram.com/promoted.png',
      );
      final speculative = overlay.load(
        policy,
        other,
        identity: 'instagram:promoted:0:thumb',
        prefetch: true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(requests, 1);
      final visibleSubscriber = overlay.load(
        policy,
        other,
        identity: 'instagram:promoted:0:thumb',
      );
      await promotedStarted.future.timeout(const Duration(seconds: 3));
      await speculative;
      await visibleSubscriber;
      expect(promoted, isTrue);
      expect(requests, 2);
      foreground.complete(http.Response.bytes(png, 200));
      await viewing;
      expect(visible, isEmpty);
      client.close();
    },
  );
}
