import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:easysave/core/models.dart';
import 'package:easysave/core/media_request.dart';
import 'package:easysave/services/parse_service.dart';
import 'package:easysave/services/shared_preview_cache.dart';
import 'package:easysave/services/media_request_policy.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:easysave/widgets/shared.dart';
import 'package:easysave/widgets/gallery_browser.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _Harness {
  _Harness(this.id) : channel = MethodChannel('test/cache-orders/$id') {
    client = MockClient((request) async {
      imageRequests++;
      return http.Response.bytes(png, 200);
    });
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'thumbnailDirectory')
        return 'build/build21-synthetic-cache/$id';
      expect((call.arguments as Map?)?.containsKey('bytes') ?? false, isFalse);
      final args = Map<String, dynamic>.from(call.arguments as Map);
      switch (call.method) {
        case 'lookupParsed':
          final value = posts.values
              .where((value) => (value['keys'] as List).contains(args['key']))
              .firstOrNull;
          if (value == null) return {'status': 'miss'};
          return {
            'status': (value['expires'] as int) <= now.millisecondsSinceEpoch
                ? 'expired'
                : 'hit',
            'value': value,
          };
        case 'putParsed':
          posts[args['canonical'] as String] = args;
          return null;
        case 'thumbnailRead':
          final path = files[args['key']];
          if (path != null) thumbnailHits++;
          return path;
        case 'thumbnailReady':
          final root = Directory('build/build21-synthetic-cache/$id')
            ..createSync(recursive: true);
          final path = '${root.path}/${args['key']}';
          expect(await File(args['path'] as String).exists(), isTrue);
          files[args['key'] as String] = path;
          return path;
      }
      return null;
    });
  }
  final String id;
  final MethodChannel channel;
  late final http.Client client;
  var now = DateTime.now();
  var parserRequests = 0;
  var imageRequests = 0;
  var thumbnailHits = 0;
  final posts = <String, Map<String, dynamic>>{};
  final files = <String, String>{};
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
  );
  String get url => 'https://www.xiaohongshu.com/explore/$id';
  CachedPostParser engine() => CachedPostParser(
    channel: channel,
    now: () => now,
    parseNetwork: (url, entry) async {
      parserRequests++;
      return ParseOutcome(
        data: ParsedPost(
          platform: 'xhs',
          id: id,
          url: this.url,
          author: PostAuthor(),
          items: [
            MediaItem(
              type: 'image',
              url:
                  'https://sns-img.xhscdn.com/$id.jpg?signature=$parserRequests&expires=${now.add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000}',
            ),
          ],
        ),
        rawImages: [],
      );
    },
  );
  Future<void> showThumbnail(String entry, ParseOutcome result) async {
    final cache = SharedThumbnailCache(client: client, channel: channel);
    final item = result.data.items.single;
    if (entry == 'bubble_select') {
      final policy = MediaRequestPolicy(
        SiteRegistry.current.byId(result.data.platform)!,
      );
      final resource = policy.resourcesFor(item).first;
      final token = cache.registerResource(
        policy,
        resource,
        identity: thumbnailIdentity(
          result.data.platform,
          result.data.id,
          0,
          'thumb',
        ),
      );
      final response = Completer<String?>();
      const codec = StandardMethodCodec();
      // The actual inbound Dart handler used by NativeMediaRequest.imageKey.
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            channel.name,
            codec.encodeMethodCall(MethodCall('fetchThumbnail', token)),
            (bytes) =>
                response.complete(codec.decodeEnvelope(bytes!) as String?),
          );
      expect(await response.future, isNotNull);
    } else {
      // The same ImageProvider rendered by App CoverImage, including decoding.
      final stream = CdnImage(
        item,
        platform: result.data.platform,
        thumbnailCache: cache,
      ).resolve(const ImageConfiguration());
      final ready = Completer<ImageInfo>();
      final listener = ImageStreamListener(
        (image, _) {
          if (!ready.isCompleted) ready.complete(image);
        },
        onError: (Object error, StackTrace? stack) {
          if (!ready.isCompleted) ready.completeError(error, stack);
        },
      );
      stream.addListener(listener);
      final image = await ready.future;
      expect(image.image.width, 1);
      stream.removeListener(listener);
      image.dispose();
    }
  }

  void close() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    client.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'cache diagnostics hash unsafe labels rather than leaking URL query values',
    () {
      final label = safeCacheLabel(
        'https://example.test/private?token=PRIVATE_VALUE',
      );
      expect(label, matches(r'^[a-f0-9]{16}$'));
      expect(label, isNot(contains('PRIVATE_VALUE')));
      expect(safeCacheLabel('xhs:abc123:0:thumb'), 'xhs:abc123:0:thumb');
    },
  );
  test(
    'fullscreen gallery preserves stable identity and ignores rotating media URLs',
    () {
      final first = GalleryBrowserItem(
        index: 4,
        cachePostId: 'abc123',
        type: 'image',
        url: 'https://sns-img.xhscdn.com/first.jpg',
      ).toMediaItem();
      final second = GalleryBrowserItem(
        index: 4,
        cachePostId: 'abc123',
        type: 'image',
        url: 'https://sns-img.xhscdn.com/second.jpg?signature=new',
      ).toMediaItem();
      expect(first.cachePostId, 'abc123');
      expect(first.cacheItemIndex, 4);
      expect(
        CdnImage(first, platform: 'xhs'),
        CdnImage(second, platform: 'xiaohongshu'),
      );
      expect(first.toJson().containsKey('cachePostId'), isFalse);
      expect(first.toJson().containsKey('cacheItemIndex'), isFalse);
    },
  );
  final orders = [
    ['app_input', 'bubble_select'],
    ['bubble_select', 'app_input'],
    ['bubble_select', 'bubble_open_app'],
    ['bubble_open_app', 'bubble_select'],
  ];
  for (var index = 0; index < orders.length; index++) {
    final order = orders[index];
    test(
      '${order[0]} then ${order[1]} reuses central parse and actual thumbnail consumers',
      () async {
        final harness = _Harness('aa${index}bb123');
        addTearDown(harness.close);
        var loading = 0;
        final first = await harness.engine().parse(
          harness.url,
          entry: order[0],
          onCacheMiss: () {
            loading++;
          },
        );
        await harness.showThumbnail(order[0], first);
        final second = await harness.engine().parse(
          harness.url,
          entry: order[1],
          onCacheMiss: () {
            loading++;
          },
        );
        await harness.showThumbnail(order[1], second);
        expect(harness.parserRequests, 1);
        expect(harness.imageRequests, 1);
        expect(loading, 1);
        expect(harness.thumbnailHits, 1);
      },
    );
  }
  test(
    'URL signature changes after forced refresh keep the stable thumbnail identity',
    () async {
      final harness = _Harness('signature123');
      addTearDown(harness.close);
      final first = await harness.engine().parse(harness.url);
      await harness.showThumbnail('bubble_select', first);
      final refreshed = await harness.engine().parse(
        harness.url,
        entry: 'history_refresh',
        forceRefresh: true,
      );
      expect(
        refreshed.data.items.single.url,
        isNot(first.data.items.single.url),
      );
      await harness.showThumbnail('app_input', refreshed);
      expect(harness.parserRequests, 2);
      expect(harness.imageRequests, 1);
      expect(harness.thumbnailHits, 1);
    },
  );
  test(
    'TTL is ten minutes and expired media causes a fresh parse sooner',
    () async {
      final harness = _Harness('expiry123');
      addTearDown(harness.close);
      await harness.engine().parse(harness.url);
      harness.now = harness.now.add(const Duration(minutes: 9));
      await harness.engine().parse(harness.url);
      expect(harness.parserRequests, 1);
      harness.now = harness.now.add(const Duration(minutes: 2));
      await harness.engine().parse(harness.url);
      expect(harness.parserRequests, 2);
      final envelope = harness.posts.values.single;
      final post = envelope['post'] as Map;
      final item = (post['items'] as List).single as Map;
      item['url'] =
          'https://sns-img.xhscdn.com/expired.jpg?expires=${harness.now.subtract(const Duration(seconds: 1)).millisecondsSinceEpoch ~/ 1000}';
      await harness.engine().parse(harness.url);
      expect(harness.parserRequests, 3);
    },
  );
  test(
    'share, history and batch use the same central cache as both bubble entries',
    () async {
      final harness = _Harness('allentries123');
      addTearDown(harness.close);
      await harness.engine().parse(harness.url, entry: 'app_input');
      for (final entry in [
        'share',
        'history',
        'batch',
        'bubble_select',
        'bubble_open_app',
      ]) {
        await harness.engine().parse(
          harness.url,
          entry: entry,
          onCacheMiss: () =>
              fail('A cache hit must not display parsing loading'),
        );
      }
      expect(harness.parserRequests, 1);
    },
  );
  test(
    'RAM snapshots retain explicit requirements and reject their expiry',
    () async {
      final harness = _Harness('requirements123');
      addTearDown(harness.close);
      var requests = 0;
      CachedPostParser engine() => CachedPostParser(
        channel: harness.channel,
        now: () => harness.now,
        parseNetwork: (url, entry) async {
          requests++;
          const address = 'https://sns-img.xhscdn.com/requirements.jpg';
          return ParseOutcome(
            data: ParsedPost(
              platform: 'xhs',
              id: harness.id,
              url: harness.url,
              author: PostAuthor(),
              items: [
                MediaItem(
                  type: 'image',
                  url: address,
                  requestResources: [
                    MediaRequestResource(
                      role: MediaResourceRole.image,
                      url: address,
                      request: MediaRequestRequirements(
                        headers: {'Referer': 'https://www.xiaohongshu.com/'},
                        cookieDomains: [],
                        transport: MediaTransport.background,
                        resumable: true,
                        expiresAt: harness.now.add(const Duration(minutes: 1)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            rawImages: [],
          );
        },
      );
      await engine().parse(harness.url);
      final cached = await engine().parse(harness.url);
      expect(requests, 1);
      expect(
        cached.data.items.single.requestResources!.single.request.headers,
        contains('Referer'),
      );
      expect(
        cached.data.items.single.requestResources!.single.request.expiresAt,
        isNotNull,
      );
      harness.now = harness.now.add(const Duration(minutes: 2));
      await engine().parse(harness.url);
      expect(requests, 2);
    },
  );
  test(
    'an unseen short-link alias resolves identity before requesting a parser',
    () async {
      final harness = _Harness('shortalias123');
      addTearDown(harness.close);
      await harness.engine().parse(harness.url);
      final parser = CachedPostParser(
        channel: harness.channel,
        parseNetwork: (_, _) async => throw StateError('Must not parse again'),
        resolveIdentityUrl: (_) async => harness.url,
      );
      final result = await parser.parse(
        'https://xhslink.com/o/newAlias',
        entry: 'bubble_select',
      );
      expect(result.data.id, harness.id);
      expect(harness.parserRequests, 1);
    },
  );
}
