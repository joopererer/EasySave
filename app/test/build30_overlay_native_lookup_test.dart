import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:easysave/core/models.dart';
import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/media_header_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final _post = ParsedPost(
  platform: 'xhs',
  id: 'native-post',
  url: 'https://www.xiaohongshu.com/explore/native-post',
  author: PostAuthor(),
  items: [
    for (var i = 1; i <= 9; i++)
      MediaItem(type: 'image', url: 'https://img.example/$i.jpg'),
  ],
);

/// What native MediaStore returns to EasySave for its albums: its own three
/// saves plus a foreign file that only a read permission would reveal.
Map<Object?, Object?> _native(String permission, {bool foreign = false}) => {
  'permission': permission,
  'sdk': 34,
  'items': [
    for (final (id, index) in [('101', 1), ('103', 3), ('105', 5)])
      {
        'id': id,
        'title': 'xhs_native-post_$index.jpg',
        'type': 'image',
        'width': 1080,
        'height': 1440,
        'relativePath': 'Pictures/EasySave/',
        'owned': true,
      },
    if (foreign)
      {'id': '900', 'title': 'other.jpg', 'type': 'image', 'owned': false},
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final locator = GalleryLocatorService.instance;
  late HistoryDb db;
  final logs = <String>[];

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
    logs.clear();
    debugPrint = (message, {wrapWidth}) => logs.add(message ?? '');
    await db.upsert(
      HistoryRecord(
        platform: 'xhs',
        postId: _post.id,
        postUrl: _post.url,
        fileCount: 3,
        createdAt: DateTime.now(),
        files: [
          for (final (id, index) in [('101', 1), ('103', 3), ('105', 5)])
            HistoryFile(
              filename: 'xhs_native-post_$index.jpg',
              savedAt: 1,
              itemIndex: index,
              mediaId: id,
            ),
        ],
      ),
      userSave: true,
    );
  });

  tearDown(() {
    debugPrint = debugPrintThrottled;
    MediaHeaderService.headerReader = null;
    locator.resetForTesting();
    HistoryDb.resetInstanceForTesting();
  });

  test('background engine finds own saves when the plugin says notDetermined',
      () async {
    locator.permissionReaderForTesting =
        () async => PermissionState.notDetermined;
    locator.nativeIndexReaderForTesting = (albums) async {
      expect(albums, isNotEmpty);
      return _native('denied');
    };
    final saved = await locator.findDownloadedIndices(_post, refreshAlbum: true);
    expect(saved, {0, 2, 4});
    expect(locator.lookupMethod, 'native');
    final line = logs.lastWhere((l) => l.contains('[SavedLookup]'));
    expect(line, contains('method=native'));
    expect(line, contains('permission=denied'));
    expect(line, contains('pluginPermission=notDetermined'));
    expect(line, contains('owned=3'));
  });

  test('foreground plugin and background native lookups agree', () async {
    // Foreground: photo_manager has access and scans the same album.
    locator.permissionReaderForTesting = () async => PermissionState.authorized;
    locator.albumReaderForTesting = () async => [
      for (final (id, index) in [('101', 1), ('103', 3), ('105', 5)])
        AssetEntity(
          id: id,
          typeInt: AssetType.image.index,
          width: 1080,
          height: 1440,
          title: 'xhs_native-post_$index.jpg',
        ),
    ];
    locator.presenceProbeForTesting = (id) async => {'101', '103', '105'}.contains(id);
    final foreground = await locator.findDownloadedIndices(_post, refreshAlbum: true);
    expect(locator.lookupMethod, 'plugin');

    locator.resetForTesting();
    locator.permissionReaderForTesting =
        () async => PermissionState.notDetermined;
    locator.nativeIndexReaderForTesting = (_) async => _native('granted', foreign: true);
    final background = await locator.findDownloadedIndices(_post, refreshAlbum: true);
    expect(background, foreground);
    expect(background, {0, 2, 4});
  });

  test('a save missing from MediaStore is not reported, and a rescan sees it',
      () async {
    locator.permissionReaderForTesting =
        () async => PermissionState.notDetermined;
    var items = _native('denied');
    locator.nativeIndexReaderForTesting = (_) async => items;
    items = {
      ...items,
      'items': (items['items'] as List).where((i) => (i as Map)['id'] != '103').toList(),
    };
    expect(await locator.findDownloadedIndices(_post, refreshAlbum: true), {0, 4});
    items = _native('denied');
    expect(await locator.findDownloadedIndices(_post, refreshAlbum: true), {0, 2, 4});
  });

  test('without a native bridge the lookup degrades to nothing saved', () async {
    locator.permissionReaderForTesting =
        () async => PermissionState.notDetermined;
    locator.nativeIndexReaderForTesting = (_) async => throw StateError('no bridge');
    expect(await locator.findDownloadedIndices(_post, refreshAlbum: true), isEmpty);
    expect(logs.any((l) => l.contains('event=native_unavailable')), isTrue);
  });
}
