import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:easysave/core/media_request.dart';
import 'package:easysave/core/models.dart';
import 'package:easysave/services/download_claims.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/preview_video.dart';
import 'package:easysave/services/media_request_policy.dart';
import 'package:easysave/services/shared_preview_cache.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:easysave/widgets/gallery_browser.dart';
import 'package:easysave/widgets/shared.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FixturePathProvider extends PathProviderPlatform {
  @override
  Future<String?> getTemporaryPath() async {
    final directory = Directory('build/v149/media-consumers');
    directory.createSync(recursive: true);
    return directory.absolute.path;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final manager = DownloadManager.instance;
  late PathProviderPlatform originalPathProvider;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    originalPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FixturePathProvider();
  });
  tearDownAll(() => PathProviderPlatform.instance = originalPathProvider);
  setUp(() async {
    SiteRegistry.useBuiltin();
    SharedPreferences.setMockInitialValues({});
    manager.clearBatchesForTesting();
    HistoryDb.resetInstanceForTesting();
    await HistoryDb.instance(dbPath: ':memory:');
    manager.prepareStartForTesting = () async {};
    manager.enqueueForTesting = (_, _) async {};
  });
  tearDown(() async {
    for (final batch in await manager.liveBatches()) {
      await DownloadClaims.release(batch.batchId);
    }
    manager.prepareStartForTesting = null;
    manager.enqueueForTesting = null;
    manager.clearBatchesForTesting();
    HistoryDb.resetInstanceForTesting();
    SiteRegistry.useBuiltin();
  });

  for (final type in ['image', 'video']) {
    test(
      'Instagram $type real media consumers retain original URL, thumbnail only in thumbnail consumer',
      () async {
        const image = 'https://scontent.cdninstagram.com/original.jpg';
        const video = 'https://scontent.cdninstagram.com/original.mp4';
        const thumb = 'https://scontent.cdninstagram.com/small.jpg';
        final policy = MediaRequestPolicy(
          SiteRegistry.current.byId('instagram')!,
        );
        final raw = MediaItem(
          type: type,
          url: image,
          videoUrl: type == 'video' ? video : null,
          thumbnailUrl: thumb,
        );
        final item =
            MediaItem(
                type: type,
                url: raw.url,
                videoUrl: raw.videoUrl,
                thumbnailUrl: raw.thumbnailUrl,
                requestResources: policy.resourcesFor(raw),
              )
              ..cachePostId = 'consumer-$type'
              ..cacheItemIndex = 0;
        final post = ParsedPost(
          platform: 'instagram',
          id: 'consumer-$type',
          url: 'https://www.instagram.com/p/consumer/',
          author: PostAuthor(),
          items: [item],
        );

        // Actual download entrypoint plans and validates before its isolated IO.
        final batch = await manager.startBatch(
          post,
          [0],
          album: 'fixture',
          nameFor: (_, _, ext) => 'consumer-$type.$ext',
        );
        expect(batch.jobs.single.urls, [type == 'video' ? video : image]);
        expect(
          batch.jobs.single.resources.single.url,
          type == 'video' ? video : image,
        );
        expect(batch.jobs.single.urls, isNot(contains(thumb)));

        // Actual browser roundtrip; obtainKey is the ImageProvider policy gate.
        final gallery = GalleryBrowserItem.fromMediaItem(item, index: 0);
        final full = gallery.toMediaItem();
        await CdnImage(
          full,
          platform: 'instagram',
        ).obtainKey(ImageConfiguration.empty);
        expect(full.url, image);
        expect(full.videoUrl, type == 'video' ? video : null);
        if (type == 'video') {
          final requests = <String>[];
          final controller = await http.runWithClient(
            () => networkPreviewController(video, 'instagram', item: full),
            () => MockClient((request) async {
              requests.add(request.url.toString());
              return http.Response.bytes([0, 0, 0, 24], 200);
            }),
          );
          expect(requests, [video]);
          await controller.dispose();
        }

        // Native bubble image requests enter Dart through fetchThumbnail. Use a
        // valid local PNG cache hit so the test exercises its real handler and
        // policy without reaching a CDN or depending on native decoding.
        final cacheChannel = MethodChannel('test/consumer-$type');
        final fixture = File('build/v149/media-consumers/$type.png');
        fixture.parent.createSync(recursive: true);
        fixture.writeAsBytesSync(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
          ),
        );
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(cacheChannel, (call) async {
          if (call.method == 'thumbnailRead') return fixture.absolute.path;
          return null;
        });
        final cache = SharedThumbnailCache(channel: cacheChannel);
        final resources = policy.resourcesFor(item);
        if (type == 'video') {
          // The bubble's videoRequest authorizes videoUrl ?? url from this set.
          final nativeVideo = await policy.authorize(resources.singleWhere(
            (resource) => resource.url == (item.videoUrl ?? item.url),
          ));
          expect(nativeVideo.resource.role, MediaResourceRole.video);
          expect(nativeVideo.uri.toString(), video);
        }
        final fullResource = resources.firstWhere((r) => r.url == image);
        final key = cache.registerResource(
          policy,
          fullResource,
          identity: 'instagram:consumer-$type:0:image',
        );
        final result = Completer<String?>();
        const codec = StandardMethodCodec();
        await messenger.handlePlatformMessage(
          cacheChannel.name,
          codec.encodeMethodCall(MethodCall('fetchThumbnail', key)),
          (bytes) => result.complete(codec.decodeEnvelope(bytes!) as String?),
        );
        expect(await result.future, fixture.absolute.path);
        expect(
          fullResource.role,
          type == 'video' ? MediaResourceRole.poster : MediaResourceRole.image,
        );
        expect(
          resources.firstWhere((r) => r.url == thumb).role,
          MediaResourceRole.poster,
        );
        messenger.setMockMethodCallHandler(cacheChannel, null);
        cacheChannel.setMethodCallHandler(null);
      },
    );
  }
}
