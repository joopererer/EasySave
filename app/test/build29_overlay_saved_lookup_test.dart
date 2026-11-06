import 'dart:typed_data';

import 'package:easysave/core/models.dart';
import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/media_header_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

AssetEntity _asset(String id, String title) => AssetEntity(
  id: id,
  typeInt: AssetType.image.index,
  width: 100,
  height: 100,
  title: title,
);

final _post = ParsedPost(
  platform: 'xhs',
  id: 'overlay-post',
  url: 'https://www.xiaohongshu.com/explore/overlay-post',
  author: PostAuthor(),
  items: [
    for (var i = 1; i <= 6; i++)
      MediaItem(type: 'image', url: 'https://img.example/$i.jpg'),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final locator = GalleryLocatorService.instance;
  late HistoryDb db;
  // Album contents written by the foreground download: items 1, 3 and 5.
  final album = [
    _asset('m1', 'xhs_overlay-post_1.jpg'),
    _asset('m3', 'xhs_overlay-post_3.jpg'),
    _asset('m5', 'xhs_overlay-post_5.jpg'),
  ];

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    HistoryDb.resetInstanceForTesting();
    db = await HistoryDb.instance(dbPath: ':memory:');
    HistoryDb.setInstanceForTesting(db);
    await db.clear();
    locator.resetForTesting();
    MediaHeaderService.headerReader = (_, _) async => Uint8List(0);
  });

  tearDown(() {
    MediaHeaderService.headerReader = null;
    locator.resetForTesting();
    HistoryDb.resetInstanceForTesting();
  });

  Future<void> foregroundSaves() => db.upsert(
    HistoryRecord(
      platform: 'xhs',
      postId: _post.id,
      postUrl: _post.url,
      fileCount: 3,
      createdAt: DateTime.now(),
      files: [
        // Inferred rows: no mediaId/assetId, confirmed only by the album scan.
        for (final index in [1, 3, 5])
          HistoryFile(
            filename: 'xhs_overlay-post_$index.jpg',
            savedAt: 1,
            itemIndex: index,
          ),
      ],
    ),
    userSave: true,
  );

  /// The background engine's locator: permission never read, nothing scanned.
  void freshBackgroundEngine({required List<AssetEntity> albumNow}) {
    locator.resetForTesting();
    locator.permissionReaderForTesting =
        () async => PermissionState.authorized;
    locator.albumReaderForTesting = () async => albumNow;
    locator.presenceProbeForTesting =
        (id) async => albumNow.any((asset) => asset.id == id);
  }

  test('background engine reports the foreground-saved items', () async {
    await foregroundSaves();

    // Foreground: start-up granted permission and scanned the album.
    locator.setScannedForTesting(
      scanned: true,
      permission: PermissionState.authorized,
      assets: album,
    );
    locator.presenceProbeForTesting =
        (id) async => album.any((asset) => asset.id == id);
    final foreground = await locator.findDownloadedIndices(_post);
    expect(foreground, {0, 2, 4});

    freshBackgroundEngine(albumNow: album);
    expect(locator.hasAccess, isFalse);
    final background = await locator.findDownloadedIndices(
      _post,
      refreshAlbum: true,
    );
    expect(background, foreground);
  });

  test('background album index older than the foreground save is refreshed',
      () async {
    // The background engine scanned before anything was saved.
    freshBackgroundEngine(albumNow: const []);
    expect(await locator.findDownloadedIndices(_post), isEmpty);
    expect(locator.scanned, isTrue);

    // The foreground then saves items 1, 3 and 5.
    await foregroundSaves();
    locator.albumReaderForTesting = () async => album;
    locator.presenceProbeForTesting =
        (id) async => album.any((asset) => asset.id == id);

    expect(
      await locator.findDownloadedIndices(_post, refreshAlbum: true),
      {0, 2, 4},
    );
  });

  test('saved state is decided again on every panel open', () async {
    await foregroundSaves();
    freshBackgroundEngine(albumNow: album);
    expect(
      await locator.findDownloadedIndices(_post, refreshAlbum: true),
      {0, 2, 4},
    );

    // Item 3 disappears from the album between two panel opens.
    final remaining = [album[0], album[2]];
    locator.albumReaderForTesting = () async => remaining;
    locator.presenceProbeForTesting =
        (id) async => remaining.any((asset) => asset.id == id);
    expect(
      await locator.findDownloadedIndices(_post, refreshAlbum: true),
      {0, 4},
    );
  });
}
