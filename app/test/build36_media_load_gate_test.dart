// Build 36: no local media request may hang forever or hold a slot forever.
//
// The device logs of build 35 showed the album path (photo_manager/MediaStore),
// not the network cache, as the stall: lookups that never settled kept the
// plugin's 8-thread executor busy and every thumbnail behind them waited until
// the app restarted. These tests pin the properties that prevent it.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:easysave/services/local_media.dart';
import 'package:easysave/services/media_header_service.dart';
import 'package:easysave/services/media_load_gate.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';

AssetEntity _asset(String id, {bool video = false}) => AssetEntity(
  id: id,
  typeInt: video ? AssetType.video.index : AssetType.image.index,
  width: 8,
  height: 8,
);

/// Every call the app would make to photo_manager, counted; [hang] makes a
/// chosen asset behave like the stuck request seen on device (no result, ever).
class _FakeLocalMedia implements LocalMediaApi {
  _FakeLocalMedia({Set<String>? hang}) : hang = hang ?? <String>{};

  final Set<String> hang;
  final Map<String, int> calls = {};
  final List<String> order = [];

  void _count(String name) {
    calls[name] = (calls[name] ?? 0) + 1;
    order.add(name);
  }

  Future<T> _never<T>() => Completer<T>().future;

  @override
  Future<PermissionState> permission(RequestType type) async =>
      PermissionState.authorized;

  @override
  Future<List<AssetPathEntity>> assetPaths({
    required RequestType type,
    required bool hasAll,
    FilterOptionGroup? filter,
  }) async {
    _count('assetPaths');
    return const [];
  }

  @override
  Future<int> assetCount(AssetPathEntity path) async => 0;

  @override
  Future<List<AssetEntity>> assetRange(
    AssetPathEntity path,
    int start,
    int end,
  ) async => const [];

  @override
  Future<AssetEntity?> assetById(String id) async {
    _count('fromId');
    if (hang.contains(id)) return _never<AssetEntity?>();
    return _asset(id);
  }

  @override
  Future<bool> assetExists(AssetEntity asset) async {
    _count('exists');
    if (hang.contains(asset.id)) return _never<bool>();
    return true;
  }

  @override
  Future<Uint8List?> thumbnail(AssetEntity asset, ThumbnailSize size) async {
    _count('thumbnailDataWithSize');
    if (hang.contains(asset.id)) return _never<Uint8List?>();
    return Uint8List.fromList(const [1, 2, 3]);
  }

  @override
  Future<File?> file(AssetEntity asset, {required bool isOrigin}) async {
    _count(isOrigin ? 'getFullFile:origin' : 'getFullFile');
    if (hang.contains(asset.id)) return _never<File?>();
    return null;
  }

  @override
  Future<String?> mediaUri(AssetEntity asset) async {
    _count('getMediaUrl');
    if (hang.contains(asset.id)) return _never<String?>();
    return 'content://media/external/video/media/${asset.id}';
  }

  @override
  Future<List<AssetEntity>> c2paAssets() async => const [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeLocalMedia api;

  setUp(() {
    api = _FakeLocalMedia();
    LocalMedia.impl = api;
    MediaLoadGate.resetForTesting();
    MediaLoadGate.limits = MediaLoadLimits(
      cover: const Duration(milliseconds: 120),
      thumb: const Duration(milliseconds: 120),
      original: const Duration(milliseconds: 120),
      video: const Duration(milliseconds: 120),
      live: const Duration(milliseconds: 120),
      lookup: const Duration(milliseconds: 120),
    );
    MediaHeaderService.sizeReader = (id, video) async => null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('easysave/media'), (
          call,
        ) async {
          return null;
        });
  });

  tearDown(() {
    LocalMedia.resetForTesting();
    MediaLoadGate.resetForTesting();
    MediaHeaderService.sizeReader = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('easysave/media'), null);
  });

  test('a stuck original times out and gives its slot back', () async {
    api.hang.add('giant');
    await expectLater(
      LocalMedia.originalBytes(_asset('giant')),
      throwsA(isA<MediaLoadTimeout>()),
    );
    final original = MediaLoadGate.snapshot(MediaLoadPool.original);
    expect(original.active, 0, reason: 'the slot must not stay taken');
    expect(original.abandoned, greaterThanOrEqualTo(1));
  });

  test('a stuck original does not slow down thumbnails of other posts', () async {
    api.hang.add('giant');
    final slow = LocalMedia.originalBytes(_asset('giant'));
    final watch = Stopwatch()..start();
    final thumb = await LocalMedia.thumbnail(
      _asset('other-post'),
      const ThumbnailSize.square(400),
    );
    watch.stop();
    expect(thumb, isNotNull);
    expect(
      watch.elapsedMilliseconds,
      lessThan(MediaLoadGate.limits.original.inMilliseconds),
      reason: 'thumbnails have their own pool and must not queue behind it',
    );
    expect(MediaLoadGate.snapshot(MediaLoadPool.original).active, 1);
    await expectLater(slow, throwsA(isA<MediaLoadTimeout>()));
    expect(MediaLoadGate.snapshot(MediaLoadPool.original).active, 0);
  });

  test('a stuck thumbnail times out and frees the thumbnail pool', () async {
    api.hang.add('stuck-thumb');
    await expectLater(
      LocalMedia.thumbnail(_asset('stuck-thumb'), const ThumbnailSize.square(400)),
      throwsA(isA<MediaLoadTimeout>()),
    );
    expect(MediaLoadGate.snapshot(MediaLoadPool.thumb).active, 0);
    expect(
      await LocalMedia.thumbnail(_asset('next'), const ThumbnailSize.square(400)),
      isNotNull,
    );
  });

  test('the queue itself is deadlined: waiters time out, not just the action', () async {
    MediaLoadGate.sizes = const MediaLoadPoolSizes(thumb: 1);
    api.hang.add('first');
    final first = LocalMedia.thumbnail(_asset('first'), const ThumbnailSize.square(400));
    final second = LocalMedia.thumbnail(_asset('second'), const ThumbnailSize.square(400));
    await expectLater(second, throwsA(isA<MediaLoadTimeout>()));
    await expectLater(first, throwsA(isA<MediaLoadTimeout>()));
    expect(MediaLoadGate.snapshot(MediaLoadPool.thumb).active, 0);
    expect(MediaLoadGate.snapshot(MediaLoadPool.thumb).queued, 0);
  });

  test('closing a page cancels its pending requests and releases the slots', () async {
    final scope = MediaLoadScope('history-page');
    api.hang.addAll(['a', 'b']);
    final a = LocalMedia.thumbnail(
      _asset('a'),
      const ThumbnailSize.square(400),
      scope: scope,
    );
    final b = LocalMedia.originalBytes(_asset('b'), scope: scope);
    scope.dispose();
    await expectLater(a, throwsA(isA<MediaLoadCancelled>()));
    await expectLater(b, throwsA(isA<MediaLoadCancelled>()));
    expect(MediaLoadGate.snapshot(MediaLoadPool.thumb).active, 0);
    expect(MediaLoadGate.snapshot(MediaLoadPool.original).active, 0);
  });

  test('a video is played from its content uri, never from a copied file', () async {
    final uri = await LocalMedia.mediaUri(_asset('clip', video: true));
    expect(uri, startsWith('content://'));
    expect(api.calls['getFullFile:origin'], isNull);
    expect(api.calls['getFullFile'], isNull);
    expect(api.calls['getMediaUrl'], 1);
  });

  test('an existing file is not read as original bytes just to check it', () async {
    expect(await LocalMedia.assetExists(_asset('saved')), isTrue);
    expect(api.calls['getFullFile'], isNull);
    expect(api.calls['getFullFile:origin'], isNull);
  });
}