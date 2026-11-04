import 'dart:io';
import 'dart:convert';
import 'package:easysave/core/models.dart';
import 'package:easysave/services/shared_preview_cache.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:easysave/services/media_request_policy.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
  );
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Dart downloads with policy headers and both consumers reuse the same cache file',
    () async {
      final policy = MediaRequestPolicy(
        SiteRegistry.current.byId('instagram')!,
      );
      final resource = policy
          .resourcesFor(
            MediaItem(
              type: 'image',
              url: 'https://scontent.cdninstagram.com/synthetic.jpg',
            ),
          )
          .first;
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        expect(request.headers['Referer'], 'https://www.instagram.com/');
        expect(request.headers.containsKey('Cookie'), isFalse);
        return http.Response.bytes(png, 200);
      });
      const channel = MethodChannel('test/shared-thumbnails');
      final files = <String, String>{};
      final root = Directory('build/build20-synthetic-thumbnails')
        ..createSync(recursive: true);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            final args = call.arguments as Map;
            final key = args['key'] as String;
            expect(key, matches(r'^[a-f0-9]{64}$'));
            if (call.method == 'thumbnailRead') return files[key];
            if (call.method != 'thumbnailWrite') return null;
            if (call.method == 'thumbnailAcquire' ||
                call.method == 'thumbnailRelease')
              return null;
            final path = '${root.path}/$key';
            await File(path).writeAsBytes((args['bytes'] as List).cast<int>());
            files[key] = path;
            return path;
          });
      final foreground = SharedThumbnailCache(client: client, channel: channel);
      final background = SharedThumbnailCache(client: client, channel: channel);
      final first = await background.load(policy, resource);
      final second = await foreground.load(policy, resource);
      expect(first.path, second.path);
      expect(second.bytes, png);
      expect(requests, 1);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      client.close();
    },
  );
  test(
    'thumbnail cache rejects an unauthorized host before any network request',
    () async {
      final policy = MediaRequestPolicy(
        SiteRegistry.current.byId('instagram')!,
      );
      final allowed = policy
          .resourcesFor(
            MediaItem(
              type: 'image',
              url: 'https://scontent.cdninstagram.com/synthetic.jpg',
            ),
          )
          .first;
      var requests = 0;
      final client = MockClient((_) async {
        requests++;
        return http.Response('', 200);
      });
      final cache = SharedThumbnailCache(client: client);
      await expectLater(
        cache.load(policy, allowed.atUrl('https://evil.test/synthetic.jpg')),
        throwsA(isA<MediaPolicyException>()),
      );
      expect(requests, 0);
      client.close();
    },
  );
}
