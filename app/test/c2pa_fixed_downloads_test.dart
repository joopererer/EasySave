import 'dart:io';
import 'dart:typed_data';
import 'package:easysave/metadata/metadata_service.dart';
import 'package:easysave/services/backup/backup_service.dart';
import 'package:easysave/services/backup/saf_service.dart';
import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/history_rebuild_service.dart';
import 'package:easysave/services/provenance_pair.dart';
import 'package:easysave/services/settings.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const pairChannel = MethodChannel('easysave/provenance_pair');
const photoChannel = MethodChannel('com.fluttercandies/photo_manager');
final stamp = DateTime.utc(2026, 10, 28);
XmpProvenance provenance({String? ai = 'Creator labeled as AI-generated', String title = 'sidecar', int day = 28}) =>
  XmpProvenance(schema: 'easysave', assetId: 'synthetic-asset', capturedAt: stamp,
    capturedBy: 'EasySave/1.9.0', metadataDate: DateTime.utc(2026, 10, day),
    platform: 'tiktok', sourceId: '7674898126922140959',
    sourceUrl: 'https://www.tiktok.com/@/video/7674898126922140959',
    itemIndex: 1, itemCount: 1, aiLabel: ai, aiLabelSource: ai == null ? null : 'author', title: title);
Map<String, Object?> row(String id, String relative) => {
  'id': id, 'title': 'post_1.jpg', 'width': 100, 'height': 100,
  'type': 1, 'typeInt': 1, 'mimeType': 'image/jpeg', 'relativePath': relative,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final locator = GalleryLocatorService.instance;
  setUpAll(() { sqfliteFfiInit(); databaseFactory = databaseFactoryFfi; });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    locator.resetForTesting();
    locator.setScannedForTesting(scanned: false, permission: PermissionState.authorized, assets: []);
    HistoryDb.resetInstanceForTesting();
    messenger.setMockMethodCallHandler(photoChannel, (call) async {
      if (call.method == 'getAssetPathList') return {'data': []};
      return null;
    });
    messenger.setMockMethodCallHandler(pairChannel, (call) async {
      if (call.method == 'queryFixedMedia') return [row('download', c2paRelativePath),
        {...row('backup', c2paRelativePath), 'typeInt': 0, 'mimeType': 'application/json'}];
      if (call.method == 'readSidecar') return buildXmpXml(provenance());
      return null;
    });
  });
  tearDown(() {
    for (final channel in [pairChannel, photoChannel, const MethodChannel('gal')]) {
      messenger.setMockMethodCallHandler(channel, null);
    }
    locator.resetForTesting(); HistoryDb.resetInstanceForTesting();
  });

  test('fixed Downloads is scanned even with renamed or empty album selection; backup JSON ignored', () async {
    expect((await locator.assetsInAlbums({'Renamed'})).map((a) => a.id), ['download']);
    expect((await locator.assetsInAlbums({})).map((a) => a.id), ['download']);
    expect((await locator.allImages()).map((a) => a.id), ['download']);
  });

  test('same-name Pictures and Download buckets are both scanned and picker counts are combined', () async {
    messenger.setMockMethodCallHandler(photoChannel, (call) async {
      if (call.method == 'getAssetPathList') return {'data': [
        {'id': 'pictures-bucket', 'name': 'EasySave', 'isAll': false, 'assetCount': 1},
        {'id': 'download-bucket', 'name': 'EasySave', 'isAll': false, 'assetCount': 1},
      ]};
      if (call.method == 'getAssetCountFromPath') return 1;
      if (call.method == 'getAssetListRange') return {'data': [
        call.arguments['id'] == 'pictures-bucket' ? row('pictures', 'Pictures/EasySave/') : row('download', c2paRelativePath),
      ]};
      return null;
    });
    expect((await locator.assetsInAlbums({'EasySave'})).map((a) => a.id), ['pictures', 'download']);
    expect(await locator.albumOptions(), [(name: 'EasySave', count: 2)]);
  });

  test('rebuild restores source and AI from fixed-directory sidecar and backup retains relativePath', () async {
    final db = await HistoryDb.instance(dbPath: ':memory:');
    final result = await HistoryRebuildService.instance.rebuild(albums: {'Renamed'}, dbOverride: db,
      readHeader: (_, __) async => Uint8List.fromList([0xff, 0xd8, 0xff, 0xd9]));
    expect(result.created, 1);
    final record = (await db.getByPostId('7674898126922140959'))!;
    expect(record.platform, 'tiktok'); expect(record.aiLabel, provenance().aiLabel);
    expect(record.aiLabelSource, 'author'); expect(record.files.single.relativePath, c2paRelativePath);
    final backup = await BackupService.exportBackup(db: db, settings: AppSettings());
    expect(backup, contains(c2paRelativePath));
    await db.clear();
    await BackupService.importBackup(backup, db: db, settings: AppSettings(), restoreSettings: false);
    expect((await db.getByPostId(record.postId))!.files.single.relativePath, c2paRelativePath);
  });

  test('merged raw XMP fills missing capture fields, preserves embedded AI and takes newer user title', () {
    final embedded = buildXmpXml(provenance(ai: 'embedded AI', title: 'old', day: 27));
    final merged = mergeProvenanceXml(embedded, buildXmpXml(provenance(title: 'new')))!;
    expect(merged.aiLabel, 'embedded AI'); expect(merged.title, 'new');
    final incomplete = '<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description xmlns:dc="http://purl.org/dc/elements/1.1/" dc:title="embedded user title"/></rdf:RDF></x:xmpmeta>';
    final recovered = mergeProvenanceXml(incomplete, buildXmpXml(provenance()))!;
    expect(recovered.platform, 'tiktok'); expect(recovered.aiLabel, provenance().aiLabel);
    final bytes = writeJpegXmp(Uint8List.fromList([0xff, 0xd8, 0xff, 0xd9]), provenance(ai: null));
    final filled = mergeProvenanceXml(MetadataService.readXmpXmlFromBytes(bytes), buildXmpXml(provenance()));
    expect(filled?.aiLabel, provenance().aiLabel);
  });

  test('relativePath resolves Download file instead of same-name Pictures file', () async {
    final download = AssetEntity(id: 'download', typeInt: 1, width: 100, height: 100,
      title: 'post_1.jpg', relativePath: c2paRelativePath);
    final pictures = AssetEntity(id: 'pictures', typeInt: 1, width: 100, height: 100,
      title: 'post_1.jpg', relativePath: 'Pictures/EasySave/');
    locator.setScannedForTesting(scanned: true, permission: PermissionState.authorized,
      assets: [download, pictures], relativePaths: {'download': c2paRelativePath, 'pictures': 'Pictures/EasySave/'});
    final found = await locator.locateAssetAsync(HistoryFile(filename: 'post_1.jpg', relativePath: c2paRelativePath, savedAt: 1),
      '7674898126922140959', platform: 'tiktok');
    expect(found?.id, 'download');
  });

  test('changing album settings cannot redirect a C2PA save', () async {
    final settings = AppSettings()..albumName = 'Renamed';
    await settings.save();
    final dir = await Directory.systemTemp.createTemp('fixed_save_');
    addTearDown(() => dir.delete(recursive: true));
    final file = await File('../docs/provenance-spec/test-vectors/no-metadata.jpg').copy('${dir.path}/photo.jpg');
    await writeSidecarFor(file.path, provenance());
    messenger.setMockMethodCallHandler(const MethodChannel('gal'), (_) async => true);
    messenger.setMockMethodCallHandler(pairChannel, (call) async {
      expect(call.method, 'savePair');
      expect((call.arguments as Map).containsKey('album'), isFalse);
      return {'mediaId': 'saved', 'title': 'photo.jpg', 'relativePath': c2paRelativePath};
    });
    expect((await saveProvenancePair(file.path)).relativePath, c2paRelativePath);
    expect(await File('${file.path}.xmp').exists(), isFalse);
    expect(c2paSavedNotice, '该图片带有内容凭证，已保存到 Download/EasySave');
  });

  test('external backup rotation in the shared directory cannot delete media or full-name sidecars', () async {
    const channel = MethodChannel('fixed-directory-backup-test');
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    List<String> removed = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'listBackupDirectory') return [
        for (final name in ['photo.jpg', 'photo.jpg.xmp', 'easysave-backup-20261028-090000.json.xmp',
          'easysave-backup-20261028-090000.json', 'easysave-backup-20261028-100000.json'])
          {'name': name, 'uri': 'content://Download/EasySave/$name'},
      ];
      if (call.method == 'deleteDocuments') {
        removed = List<String>.from(call.arguments['uris']);
        return {for (final uri in removed) uri: true};
      }
      return null;
    });
    expect(await SafService.rotateBackups('content://Download/EasySave', keepCount: 1, channelOverride: channel), 1);
    expect(removed, ['content://Download/EasySave/easysave-backup-20261028-090000.json']);
  });
}
