import 'dart:typed_data';
import 'package:easysave/metadata/metadata_service.dart';
import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/history_rebuild_service.dart';
import 'package:easysave/services/provenance_pair.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final locator = GalleryLocatorService.instance;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const pair = MethodChannel('easysave/provenance_pair');
  const photo = MethodChannel('com.fluttercandies/photo_manager');
  late HistoryDb db;
  var requestedState = PermissionState.denied;
  var albumQueries = 0;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    locator.resetForTesting();
    locator.setScannedForTesting(
      scanned: false,
      permission: PermissionState.denied,
      assets: [],
    );
    HistoryDb.resetInstanceForTesting();
    db = await HistoryDb.instance(dbPath: ':memory:');
    await db.clear();
    requestedState = PermissionState.denied;
    albumQueries = 0;
    messenger.setMockMethodCallHandler(photo, (call) async {
      if (call.method == 'requestPermissionExtend' ||
          call.method == 'getPermissionState')
        return requestedState.index;
      if (call.method == 'getAssetPathList') {
        albumQueries++;
        return {'data': []};
      }
      return null;
    });
    messenger.setMockMethodCallHandler(pair, (call) async {
      if (call.method == 'queryFixedMedia')
        return [
          {
            'id': 'owned',
            'title': 'fixed.jpg',
            'typeInt': 1,
            'mimeType': 'image/jpeg',
            'relativePath': c2paRelativePath,
          },
          {
            'id': 'xmp',
            'title': 'fixed.jpg.xmp',
            'typeInt': 0,
            'mimeType': 'application/octet-stream',
            'relativePath': c2paRelativePath,
          },
        ];
      if (call.method == 'readSidecar')
        return buildXmpXml(
          XmpProvenance(
            schema: 'easysave',
            assetId: 'fixed',
            capturedAt: DateTime.utc(2026),
            metadataDate: DateTime.utc(2026),
            capturedBy: 'EasySave/1.9.0',
            platform: 'tiktok',
            sourceId: '123',
            sourceUrl: 'https://www.tiktok.com/@/video/123',
            itemIndex: 1,
            itemCount: 1,
          ),
        );
      return null;
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(pair, null);
    messenger.setMockMethodCallHandler(photo, null);
    locator.resetForTesting();
    HistoryDb.resetInstanceForTesting();
  });
  test(
    'owned fixed-directory pair rebuilds even when gallery permission is denied and another album is selected',
    () async {
      final result = await HistoryRebuildService.instance.rebuild(
        albums: {'OtherAlbum'},
        dbOverride: db,
        readHeader: (_, _) async => Uint8List(0),
      );
      expect(result.total, 1);
      expect(result.created, 1);
      expect(
        (await db.getByPostId('123'))!.files.single.relativePath,
        c2paRelativePath,
      );
      expect((await locator.allImages()).single.id, 'owned');
      expect(albumQueries, 0);
    },
  );
  test(
    'granting permission updates locator and an empty selection still rebuilds fixed directory',
    () async {
      requestedState = PermissionState.authorized;
      final result = await HistoryRebuildService.instance.rebuild(
        albums: {},
        dbOverride: db,
        readHeader: (_, _) async => Uint8List(0),
      );
      expect(locator.hasAccess, isTrue);
      expect(result.created, 1);
      expect(result.total, 1);
      expect(albumQueries, 0); // No unrelated automatic scan after granting.
    },
  );
  test(
    'fixed-directory query failure is surfaced instead of a misleading empty successful scan',
    () async {
      locator.setScannedForTesting(
        scanned: false,
        permission: PermissionState.authorized,
        assets: [],
      );
      messenger.setMockMethodCallHandler(
        pair,
        (_) async => throw PlatformException(
          code: 'provenance_pair',
          message: 'query failed',
        ),
      );
      await expectLater(
        HistoryRebuildService.instance.rebuild(albums: {}, dbOverride: db),
        throwsA(isA<PlatformException>()),
      );
      expect(await db.recent(), isEmpty);
    },
  );
}
