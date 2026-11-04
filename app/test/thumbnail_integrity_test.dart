import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:easysave/core/models.dart';
import 'package:easysave/services/media_request_policy.dart';
import 'package:easysave/services/shared_preview_cache.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:flutter/services.dart';
import 'package:flutter/painting.dart';
import 'package:easysave/widgets/shared.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
  );
  final policy = MediaRequestPolicy(SiteRegistry.current.byId('instagram')!);
  final resource = policy
      .resourcesFor(
        MediaItem(
          type: 'image',
          url: 'https://scontent.cdninstagram.com/synthetic.png',
        ),
      )
      .first;
  const channel = MethodChannel('test/integrity');
  final files = <String, String>{};
  var writes = 0;
  var deletes = 0;
  final flights = <String, List<Completer<bool>>>{};
  var prefetchAllowed = true;
  setUp(() async {
    files.clear();
    flights.clear();
    writes = 0;
    deletes = 0;
    prefetchAllowed = true;
    await Directory('build/build22-integrity').create(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'thumbnailPrefetchAllowed') return prefetchAllowed;
          final args = call.arguments as Map;
          final key = args['key'] as String;
          switch (call.method) {
            case 'thumbnailAcquire':
              if (!flights.containsKey(key)) {
                flights[key] = [];
                return true;
              }
              final wait = Completer<bool>();
              flights[key]!.add(wait);
              return wait.future;
            case 'thumbnailRelease':
              for (final wait in flights.remove(key) ?? <Completer<bool>>[]) {
                wait.complete(false);
              }
              return null;
            case 'thumbnailRead':
              return files[key];
            case 'thumbnailDelete':
              files.remove(key);
              deletes++;
              return null;
            case 'thumbnailWrite':
              writes++;
              final file = File('build/build22-integrity/$key');
              await file.writeAsBytes((args['bytes'] as List).cast<int>());
              files[key] = file.path;
              return file.path;
          }
          return null;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  test('interrupted response is retried twice and never committed', () async {
    var requests = 0;
    final client = MockClient.streaming((_, __) async {
      requests++;
      return http.StreamedResponse(
        Stream.value(png.sublist(0, 20)),
        200,
        contentLength: png.length,
      );
    });
    final cache = SharedThumbnailCache(client: client, channel: channel);
    await expectLater(
      cache.load(policy, resource, identity: 'instagram:interrupted:0:thumb'),
      throwsA(isA<HttpException>()),
    );
    expect(requests, 3);
    expect(writes, 0);
    expect(files, isEmpty);
    expect(flights, isEmpty);
    client.close();
  });
  test('partial image without content length is not cached', () async {
    final client = MockClient(
      (_) async => http.Response.bytes(png.sublist(0, png.length - 12), 200),
    );
    await expectLater(
      SharedThumbnailCache(
        client: client,
        channel: channel,
      ).load(policy, resource),
      throwsA(isA<FormatException>()),
    );
    expect(writes, 0);
    client.close();
  });
  test(
    'two independent engines download once through process flight',
    () async {
      var requests = 0;
      final client = MockClient((_) async {
        requests++;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return http.Response.bytes(png, 200);
      });
      final first = SharedThumbnailCache(client: client, channel: channel);
      final second = SharedThumbnailCache(client: client, channel: channel);
      final result = await Future.wait([
        first.load(policy, resource, identity: 'instagram:concurrent:0:thumb'),
        second.load(policy, resource, identity: 'instagram:concurrent:0:thumb'),
      ]);
      expect(requests, 1);
      expect(writes, 1);
      expect(result.first.bytes, result.last.bytes);
      expect(flights, isEmpty);
      client.close();
    },
  );
  test('corrupt cache is removed then replaced by valid image', () async {
    const identity = 'instagram:corrupt:0:thumb';
    final key = opaquePreviewKey(identity);
    final file = File('build/build22-integrity/corrupt');
    await file.writeAsBytes([1, 2, 3]);
    files[key] = file.path;
    var requests = 0;
    final client = MockClient((_) async {
      requests++;
      return http.Response.bytes(png, 200);
    });
    final result = await SharedThumbnailCache(
      client: client,
      channel: channel,
    ).load(policy, resource, identity: identity);
    expect(deletes, 1);
    expect(requests, 1);
    expect(result.bytes, png);
    expect(writes, 1);
    client.close();
  });
  test('failed flight is not permanently memoized', () async {
    var good = false;
    final client = MockClient(
      (_) async =>
          good ? http.Response.bytes(png, 200) : http.Response('', 503),
    );
    final cache = SharedThumbnailCache(client: client, channel: channel);
    await expectLater(
      cache.load(policy, resource),
      throwsA(isA<HttpException>()),
    );
    good = true;
    expect((await cache.load(policy, resource)).bytes, png);
    client.close();
  });
  test(
    'display decode failure evicts committed bytes and re-downloads once',
    () async {
      var requests = 0;
      var decodes = 0;
      final client = MockClient((_) async {
        requests++;
        return http.Response.bytes(png, 200);
      });
      final cache = SharedThumbnailCache(client: client, channel: channel);
      final provider = CdnImage(
        MediaItem(type: 'image', url: resource.url),
        platform: 'instagram',
        cacheWidth: 80,
        thumbnailCache: cache,
      );
      final completer = provider.loadImage(provider, (
        buffer, {
        getTargetSize,
      }) async {
        decodes++;
        final codec = await PaintingBinding.instance
            .instantiateImageCodecWithSize(
              buffer,
              getTargetSize: getTargetSize,
            );
        return decodes == 1 ? _BadFirstFrame(codec) : codec;
      });
      final completed = Completer<void>();
      final listener = ImageStreamListener(
        (image, _) {
          image.dispose();
          completed.complete();
        },
        onError: (Object error, StackTrace? stack) {
          completed.completeError(error, stack);
        },
      );
      completer.addListener(listener);
      await completed.future;
      completer.removeListener(listener);
      expect(deletes, 1);
      expect(requests, 2);
      expect(decodes, 2);
      client.close();
    },
  );
  ParsedPost post(int count, String id) => ParsedPost(
    platform: 'instagram',
    id: id,
    url: 'https://www.instagram.com/p/$id/',
    author: PostAuthor(),
    items: List.generate(
      count,
      (i) => MediaItem(
        type: i == 0 ? 'live' : 'image',
        url: 'https://scontent.cdninstagram.com/$i.png',
      ),
    ),
  );
  test(
    'prefetch caps at 30 and uses at most one download per engine',
    () async {
      var active = 0;
      var peak = 0;
      var requests = 0;
      final client = MockClient((_) async {
        requests++;
        active++;
        if (active > peak) peak = active;
        await Future<void>.delayed(Duration.zero);
        active--;
        return http.Response.bytes(png, 200);
      });
      final cache = SharedThumbnailCache(
        client: client,
        channel: channel,
        prefetchInterval: Duration.zero,
      );
      await cache.prefetch(post(35, 'prefetch'));
      expect(requests, 30);
      expect(peak, 1);
      expect(writes, 30);
      await cache.prefetch(post(35, 'prefetch'));
      expect(requests, 30);
      client.close();
    },
  );
  test(
    'data saver blocks prefetch and later permitted parse may try again',
    () async {
      var requests = 0;
      final client = MockClient((_) async {
        requests++;
        return http.Response.bytes(png, 200);
      });
      final cache = SharedThumbnailCache(
        client: client,
        channel: channel,
        prefetchInterval: Duration.zero,
      );
      prefetchAllowed = false;
      await cache.prefetch(post(2, 'saver'));
      expect(requests, 0);
      prefetchAllowed = true;
      await cache.prefetch(post(2, 'saver'));
      expect(requests, 2);
      client.close();
    },
  );
  test('visible request starts before queued speculative thumbnails', () async {
    final visible = Completer<http.Response>();
    final started = <String>[];
    final client = MockClient((request) async {
      started.add(request.url.path);
      if (request.url.path == '/synthetic.png') return visible.future;
      return http.Response.bytes(png, 200);
    });
    final cache = SharedThumbnailCache(
      client: client,
      channel: channel,
      prefetchInterval: Duration.zero,
    );
    final viewing = cache.load(
      policy,
      resource,
      identity: 'instagram:visible:0:thumb',
    );
    final speculative = cache.prefetch(post(2, 'priority'));
    await Future<void>.delayed(const Duration(milliseconds: 25));
    expect(started, ['/synthetic.png']);
    visible.complete(http.Response.bytes(png, 200));
    await viewing;
    await speculative;
    expect(started.length, 3);
    client.close();
  });
}

class _BadFirstFrame implements ui.Codec {
  _BadFirstFrame(this.codec);
  final ui.Codec codec;
  @override
  int get frameCount => codec.frameCount;
  @override
  int get repetitionCount => codec.repetitionCount;
  @override
  void dispose() => codec.dispose();
  @override
  Future<ui.FrameInfo> getNextFrame() =>
      Future.error(const FormatException('synthetic display decoder failure'));
}
