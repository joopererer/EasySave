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
  test(
    'cache hits finish under 100ms with foreground/prefetch downloads and display decoders blocked',
    () async {
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
      );
      final directory = await Directory(
        'build/build23-read-contention',
      ).create(recursive: true);
      final cached = File('${directory.path}/cached.png');
      await cached.writeAsBytes(png);
      const hit = 'instagram:cached:0:thumb';
      final files = <String, String>{opaquePreviewKey(hit): cached.path};
      const channel = MethodChannel('test/build23-read-contention');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'thumbnailDirectory') return directory.path;
        expect(
          (call.arguments as Map?)?.containsKey('bytes') ?? false,
          isFalse,
        );
        final args = call.arguments as Map;
        final key = args['key'] as String;
        switch (call.method) {
          case 'thumbnailAcquire':
            return true;
          case 'thumbnailPrefetchIdle':
            return true;
          case 'thumbnailRead':
            return files[key];
          case 'thumbnailReady':
            final path = '${directory.path}/$key';
            expect(await File(args['path'] as String).exists(), isTrue);
            files[key] = path;
            return path;
        }
        return null;
      });
      final policy = MediaRequestPolicy(
        SiteRegistry.current.byId('instagram')!,
      );
      final resource = policy
          .resourcesFor(
            MediaItem(
              type: 'image',
              url: 'https://scontent.cdninstagram.com/synthetic.png',
            ),
          )
          .first;
      final responses = <Completer<http.Response>>[];
      final fiveStarted = Completer<void>();
      var releasing = false;
      final client = MockClient((request) async {
        if (releasing) return http.Response.bytes(png, 200);
        final pending = Completer<http.Response>();
        responses.add(pending);
        if (responses.length == 5) fiveStarted.complete();
        return pending.future;
      });
      final cache = SharedThumbnailCache(client: client, channel: channel);
      final releaseDecode = Completer<void>();
      final decodersBusy = Completer<void>();
      var decoders = 0;
      final held = List.generate(
        2,
        (_) => SharedThumbnailCache.decodeSlots.run(() async {
          if (++decoders == 2) decodersBusy.complete();
          await releaseDecode.future;
        }),
      );
      final loads = <Future<Object>>[];
      try {
        await decodersBusy.future;
        // A speculative request already in progress must not borrow any of the
        // four visible-request permits. The remaining visible tasks queue up.
        loads.add(
          cache.load(
            policy,
            resource,
            identity: 'instagram:prefetch:0:thumb',
            prefetch: true,
          ),
        );
        while (responses.isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        for (var i = 0; i < 8; i++) {
          loads.add(
            cache.load(
              policy,
              resource,
              identity: 'instagram:foreground:$i:thumb',
            ),
          );
        }
        await fiveStarted.future.timeout(const Duration(seconds: 5));
        expect(responses.length, 5);
        final stopwatch = Stopwatch()..start();
        final result = await cache
            .load(policy, resource, identity: hit)
            .timeout(const Duration(milliseconds: 100));
        expect(result.bytes, png);
        expect(stopwatch.elapsedMilliseconds, lessThan(100));
        expect(releaseDecode.isCompleted, isFalse);
      } finally {
        releasing = true;
        for (final response in responses) {
          response.complete(http.Response.bytes(png, 200));
        }
        releaseDecode.complete();
        await Future.wait(held);
        await Future.wait(loads);
        client.close();
        messenger.setMockMethodCallHandler(channel, null);
      }
    },
  );
}
