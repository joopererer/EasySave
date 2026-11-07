import 'dart:convert';
import 'dart:io';

import 'package:easysave/services/backup/backup_model.dart';
import 'package:easysave/services/backup/backup_restore_matcher.dart';
import 'package:easysave/services/backup/backup_security.dart';
import 'package:easysave/services/backup/backup_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:provenance_dart/provenance_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _xhsA = '6ad2f7050000000012034042';
const _xhsB = '6ad2f7050000000012034043';
const _xPost = '2118566677374022101';

/// An album with known files, provenance and sizes.
class _FakeAlbum implements RestoreAlbum {
  _FakeAlbum(this.files);

  final List<({AssetEntity asset, XmpProvenance? prov, int size})> files;
  var indexCalls = 0;

  @override
  Future<bool> ensureIndexed() async {
    indexCalls++;
    return true;
  }

  @override
  List<AssetEntity> get assets => [for (final f in files) f.asset];

  @override
  AssetEntity? byId(String id) =>
      files.where((f) => f.asset.id == id).firstOrNull?.asset;

  @override
  Future<XmpProvenance?> provenance(AssetEntity asset) async =>
      files.firstWhere((f) => f.asset.id == asset.id).prov;

  @override
  Future<int?> size(AssetEntity asset) async =>
      files.firstWhere((f) => f.asset.id == asset.id).size;
}

AssetEntity _asset(String id, String title, {bool video = false}) => AssetEntity(
  id: id,
  typeInt: (video ? AssetType.video : AssetType.image).index,
  width: 1080,
  height: 1440,
  title: title,
  relativePath: 'Pictures/EasySave/',
);

XmpProvenance _prov(String platform, String sourceId, int itemIndex, {String? assetId}) =>
    XmpProvenance(
      schema: 'easysave',
      capturedBy: 'EasySave/1.10.0',
      platform: platform,
      sourceId: sourceId,
      itemIndex: itemIndex,
      assetId: assetId ?? "asset-$sourceId-$itemIndex",
      capturedAt: DateTime.utc(2026, 10, 1),
      metadataDate: DateTime.utc(2026, 10, 1),
    );

HistoryFile _file(String postId, int index, {String? mediaId, String? assetId, int? size, bool image = true}) =>
    HistoryFile(
      filename: '${postId}_$index.${image ? 'jpg' : 'mp4'}',
      savedAt: DateTime.utc(2026, 10, 1, 8).millisecondsSinceEpoch,
      mediaId: mediaId,
      status: FileStatus.found,
      itemIndex: index,
      isImage: image,
      assetId: assetId,
      relativePath: 'Pictures/EasySave/',
      itemCount: 3,
      capturedBy: 'EasySave/1.10.0',
      size: size,
    );

/// Signed CDN URLs as a parser stores them in items_json and thumbnail_url.
String _items(String id, int count) => jsonEncode([
  for (var i = 1; i <= count; i++)
    {
      'type': 'image',
      'url': 'https://sns-img-bd.xhscdn.com/notes_pre_post/$id-$i?sign=abc$i&t=1790000000',
      'thumbnailUrl': 'https://sns-webpic-qc.xhscdn.com/202610/$id-$i!nd_dft_wlteh_webp_3?sign=x',
      'fallbacks': ['https://ci.xiaohongshu.com/$id-$i?imageView2/format/jpg'],
    },
]);

HistoryRecord _xhsRecord(String id, List<HistoryFile> files, {String? error}) => HistoryRecord(
  platform: 'xhs',
  postId: id,
  authorName: 'Author $id',
  title: 'Note $id',
  caption: 'Caption $id',
  aiLabel: '内容疑似由AI生成',
  aiLabelSource: 'platform',
  thumbnailUrl: 'https://sns-webpic-qc.xhscdn.com/202610/$id-cover?sign=cover',
  postUrl: 'https://www.rednote.com/explore/$id?xsec_token=FAKE_TOKEN&xsec_source=pc_feed',
  fileCount: files.length,
  createdAt: DateTime(2026, 10, 1, 9),
  itemsJson: _items(id, 3),
  files: files,
  downloadError: error,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HistoryDb db;
  late AppSettings settings;

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
    settings = await AppSettings.load();
    BackupService.mediaSizesReader = (_) async => const {};
  });

  tearDown(() {
    BackupService.mediaSizesReader = null;
    HistoryDb.resetInstanceForTesting();
  });

  /// Two successful files of A, one failed post B, one X video, one partial A2.
  Future<void> seed() async {
    await db.upsert(_xhsRecord(_xhsA, [
      _file(_xhsA, 1, mediaId: '101', assetId: 'asset-a1', size: 1000),
      _file(_xhsA, 2, mediaId: '102', assetId: 'asset-a2', size: 2000),
    ]));
    await db.upsert(_xhsRecord(_xhsB, const [], error: 'HTTP 403'));
    await db.upsert(HistoryRecord(
      platform: 'x',
      postId: _xPost,
      authorName: 'x_author',
      title: 'Large video',
      thumbnailUrl: 'https://pbs.twimg.com/ext_tw_video_thumb/1/pu/img/a.jpg?name=orig',
      postUrl: 'https://x.com/KPKP996/status/$_xPost?s=20',
      fileCount: 1,
      createdAt: DateTime(2026, 10, 2),
      itemsJson: jsonEncode([
        {'type': 'video', 'url': 'https://video.twimg.com/ext_tw_video/1/pu/vid/720x1280/big.mp4?tag=12'},
      ]),
      files: [_file(_xPost, 1, mediaId: '301', assetId: 'asset-x1', size: 1095216660, image: false)],
    ));
  }

  _FakeAlbum albumWithSavedFiles() => _FakeAlbum([
    (asset: _asset('201', '${_xhsA}_1.jpg'), prov: _prov('xiaohongshu', _xhsA, 1, assetId: 'asset-a1'), size: 1000),
    (asset: _asset('202', '${_xhsA}_2.jpg'), prov: null, size: 2000),
    (asset: _asset('401', '${_xPost}_1.mp4', video: true), prov: _prov('x', _xPost, 1), size: 1095216660),
  ]);

  Iterable<String> urlsIn(Object? json) sync* {
    if (json is String) {
      yield* RegExp(r'''[a-z][a-z0-9+.-]*://[^\s"']+''', caseSensitive: false)
          .allMatches(json)
          .map((m) => m.group(0)!);
    } else if (json is Map) {
      for (final v in json.values) {
        yield* urlsIn(v);
      }
    } else if (json is List) {
      for (final v in json) {
        yield* urlsIn(v);
      }
    }
  }

  test('v2 contains only post URLs; only originalUrl carries a query', () async {
    await seed();
    final exported = await BackupService.exportBackup(db: db, settings: settings);
    final data = jsonDecode(exported) as Map<String, dynamic>;
    expect(data['schemaVersion'], 2);
    validateNoSensitiveKeys(data);

    final posts = (data['posts'] as List).cast<Map<String, dynamic>>();
    final allowed = <String>{
      for (final p in posts) p['originalUrl'] as String,
      for (final p in posts)
        if (p['canonicalUrl'] != null) p['canonicalUrl'] as String,
    };
    final urls = urlsIn(data).toList();
    expect(urls, isNotEmpty);
    for (final url in urls) {
      expect(allowed, contains(url), reason: 'unexpected URL in backup: $url');
    }
    for (final p in posts) {
      expect(p.containsKey('items'), isFalse);
      expect(p.containsKey('thumbnailUrl'), isFalse);
      final canonical = p['canonicalUrl'] as String?;
      if (canonical != null) expect(Uri.parse(canonical).hasQuery, isFalse);
      for (final f in (p['files'] as List).cast<Map>()) {
        expect(f.containsKey('provenance'), isFalse);
        expect(urlsIn(f), isEmpty);
      }
    }
    // Media hosts never appear anywhere.
    for (final host in ['xhscdn.com', 'twimg.com', 'ci.xiaohongshu.com']) {
      expect(exported.contains(host), isFalse, reason: host);
    }
    for (final word in ['cookie', 'Cookie', 'sessionid', 'auth_token', 'web_session']) {
      expect(exported.contains(word), isFalse, reason: word);
    }

    final a = posts.firstWhere((p) => p['sourceId'] == _xhsA);
    expect(a['platform'], 'xiaohongshu');
    expect(a['canonicalUrl'], 'https://www.xiaohongshu.com/explore/$_xhsA');
    expect(a['originalUrl'], contains('xsec_token=FAKE_TOKEN'));
    expect(a['status'], 'success');
    expect(a['author'], {'name': 'Author $_xhsA'});
    final file = (a['files'] as List).first as Map;
    expect(file, {
      'itemIndex': 1,
      'mediaType': 'image',
      'filename': '${_xhsA}_1.jpg',
      'relativePath': 'Pictures/EasySave/',
      'size': 1000,
      'assetId': 'asset-a1',
      'mediaIdHint': '101',
      'savedAt': file['savedAt'],
      'itemCount': 3,
      'capturedBy': 'EasySave/1.10.0',
    });
    final x = posts.firstWhere((p) => p['sourceId'] == _xPost);
    expect(x['canonicalUrl'], 'https://x.com/i/status/$_xPost');
  });

  test('v2 export → restore round trip on a device that has the files', () async {
    await seed();
    final before = {for (final r in await db.getAllActiveForBackup()) r.postId: r};
    final exported = await BackupService.exportBackup(db: db, settings: settings);
    await db.clear();

    final album = albumWithSavedFiles();
    final result = await BackupService.importBackup(exported, db: db, settings: settings, album: album);
    expect(result.restoredPosts, 3);

    final after = {for (final r in await db.getAllActiveForBackup()) r.postId: r};
    expect(after.keys.toSet(), before.keys.toSet());
    for (final id in before.keys) {
      final b = before[id]!;
      final r = after[id]!;
      expect(r.platform, b.platform);
      expect(r.postUrl, b.postUrl, reason: 'originalUrl restored as saved');
      expect(r.title, b.title);
      expect(r.authorName, b.authorName);
      expect(r.aiLabel, b.aiLabel);
      expect(r.aiLabelSource, b.aiLabelSource);
      expect(r.createdAt, b.createdAt);
      expect(r.downloadError, b.downloadError);
      expect(r.savedFiles.map((f) => f.itemIndex), b.savedFiles.map((f) => f.itemIndex));
      expect(r.savedFiles.map((f) => f.assetId), b.savedFiles.map((f) => f.assetId));
      expect(r.itemsJson, isNull, reason: 'no media URL comes back from a backup');
    }
    // Files are linked to this device's album ids, not the old ones.
    final a = after[_xhsA]!.files;
    expect(a.map((f) => (f.itemIndex, f.mediaId, f.status)).toList(), [
      (1, '201', FileStatus.found),
      (2, '202', FileStatus.found),
    ]);
    expect(after[_xPost]!.files.single.mediaId, '401');
  });

  test('a failed post round-trips as failed and stays retryable', () async {
    await seed();
    final exported = await BackupService.exportBackup(db: db, settings: settings);
    final b = ((jsonDecode(exported) as Map)['posts'] as List)
        .cast<Map>()
        .firstWhere((p) => p['sourceId'] == _xhsB);
    expect(b['status'], 'failed');
    expect(b['failureReason'], 'HTTP 403');
    expect(b['files'], isEmpty);

    await db.clear();
    await BackupService.importBackup(exported, db: db, settings: settings, album: albumWithSavedFiles());
    final restored = (await db.getByPostId(_xhsB, platform: 'xhs'))!;
    expect(restored.savedFiles, isEmpty);
    expect(restored.downloadError, 'HTTP 403');
    expect(restored.postUrl, contains('xsec_token=FAKE_TOKEN'),
        reason: 'retry re-parses the original link');

    final again = await BackupService.exportBackup(db: db, settings: settings);
    final b2 = ((jsonDecode(again) as Map)['posts'] as List)
        .cast<Map>()
        .firstWhere((p) => p['sourceId'] == _xhsB);
    expect(b2['status'], 'failed');
  });

  test('a v1 backup restores with its URLs dropped and mediaId only as a hint',
      () async {
    final v1 = jsonEncode({
      'format': 'easysave-backup',
      'formatVersion': 1,
      'exportedAt': '2026-10-20T10:00:00+08:00',
      'appVersion': '1.10.0',
      'provenanceSpecVersion': '0.1.7',
      'settings': {'albumName': 'EasySave'},
      'posts': [
        {
          'platform': 'xiaohongshu',
          'sourceId': _xhsA,
          'originalUrl': 'https://www.rednote.com/explore/$_xhsA?xsec_token=OLD',
          'title': 'Old note',
          'authorName': 'Old author',
          'createdAt': '2026-10-01T09:00:00+08:00',
          'items': jsonDecode(_items(_xhsA, 3)),
          'files': [
            {
              'filename': '${_xhsA}_1.jpg',
              'relativePath': 'Pictures/EasySave/',
              'savedAt': '2026-10-01T09:00:00+08:00',
              'mediaType': 'image',
              'mediaId': '201',
              'itemIndex': 1,
              'assetId': 'asset-a1',
              'provenance': {
                'schema': '0.1',
                'capturedBy': 'EasySave/1.9.0',
                'source': {
                  'url': 'https://www.rednote.com/explore/$_xhsA',
                  'platform': 'xiaohongshu',
                  'id': _xhsA,
                  'itemIndex': 1,
                  'itemCount': 3,
                },
              },
            },
            {
              // The old device's id now belongs to an unrelated file here.
              'filename': '${_xhsA}_3.jpg',
              'savedAt': '2026-10-01T09:00:00+08:00',
              'mediaType': 'image',
              'mediaId': '999',
              'itemIndex': 3,
            },
          ],
        },
        {
          'platform': 'xiaohongshu',
          'sourceId': _xhsB,
          'originalUrl': 'https://www.xiaohongshu.com/explore/$_xhsB',
          'createdAt': '2026-10-01T09:00:00+08:00',
          'items': jsonDecode(_items(_xhsB, 1)),
          'files': [],
        },
      ],
    });
    final album = _FakeAlbum([
      (asset: _asset('201', '${_xhsA}_1.jpg'), prov: _prov('xiaohongshu', _xhsA, 1, assetId: 'asset-a1'), size: 1000),
      (asset: _asset('999', 'IMG_0999.jpg'), prov: null, size: 5000),
    ]);
    final preview = BackupService.previewBackup(v1);
    expect(preview.formatVersion, 1);

    await BackupService.importBackup(v1, db: db, settings: settings, album: album);
    final a = (await db.getByPostId(_xhsA, platform: 'xhs'))!;
    expect(a.itemsJson, isNull);
    expect(a.thumbnailUrl, isNull);
    expect(a.files.firstWhere((f) => f.itemIndex == 1).mediaId, '201');
    expect(a.files.firstWhere((f) => f.itemIndex == 1).capturedBy, 'EasySave/1.9.0');
    final third = a.files.firstWhere((f) => f.itemIndex == 3);
    expect(third.mediaId, isNull, reason: 'an unverified hint is never used');
    expect(third.status, FileStatus.notFound);
    final b = (await db.getByPostId(_xhsB, platform: 'xhs'))!;
    expect(b.downloadError, '', reason: 'a v1 post without files restores as failed');

    // Writing always uses v2.
    final out = jsonDecode(await BackupService.exportBackup(db: db, settings: settings)) as Map;
    expect(out['schemaVersion'], 2);
    expect(urlsIn(out).where((u) => u.contains('xhscdn')), isEmpty);
  });

  test("restore never links post A's file to post B", () async {
    final backup = jsonEncode(BackupData(
      exportedAt: '2026-10-22T10:00:00+08:00',
      settings: BackupSettings(),
      posts: [
        BackupPost(
          platform: 'xiaohongshu',
          sourceId: _xhsA,
          originalUrl: 'https://www.xiaohongshu.com/explore/$_xhsA',
          savedAt: '2026-10-01T09:00:00+08:00',
          files: [
            // Hint points at B's file, which even has the same size.
            BackupFile(itemIndex: 1, mediaType: 'image', filename: '${_xhsA}_1.jpg',
                mediaIdHint: '502', size: 7000, assetId: 'asset-a1', savedAt: '2026-10-01T09:00:00+08:00'),
            // Generic name shared with another file of B.
            BackupFile(itemIndex: 2, mediaType: 'image', filename: 'IMG_0001.jpg',
                savedAt: '2026-10-01T09:00:00+08:00'),
          ],
        ),
        BackupPost(
          platform: 'xiaohongshu',
          sourceId: _xhsB,
          originalUrl: 'https://www.xiaohongshu.com/explore/$_xhsB',
          savedAt: '2026-10-01T09:00:00+08:00',
          files: [
            BackupFile(itemIndex: 1, mediaType: 'image', filename: '${_xhsB}_1.jpg',
                savedAt: '2026-10-01T09:00:00+08:00'),
          ],
        ),
      ],
    ).toMap());
    final album = _FakeAlbum([
      (asset: _asset('502', '${_xhsB}_1.jpg'), prov: _prov('xiaohongshu', _xhsB, 1), size: 7000),
      (asset: _asset('503', 'IMG_0001.jpg'), prov: _prov('xiaohongshu', _xhsB, 2), size: 10),
      // A file named like A's but whose provenance says it belongs to B.
      (asset: _asset('504', '${_xhsA}_2.jpg'), prov: _prov('xiaohongshu', _xhsB, 3), size: 10),
    ]);
    await BackupService.importBackup(backup, db: db, settings: settings, album: album);
    final a = (await db.getByPostId(_xhsA, platform: 'xhs'))!;
    expect(a.files.map((f) => f.mediaId), everyElement(isNull));
    expect(a.files.map((f) => f.status), everyElement(FileStatus.notFound));
    final b = (await db.getByPostId(_xhsB, platform: 'xhs'))!;
    expect(b.files.single.mediaId, '502');
  });

  test('restoring the same backup twice gives the same history', () async {
    await seed();
    final exported = await BackupService.exportBackup(db: db, settings: settings);
    await db.clear();
    Future<List<Map<String, Object?>>> snapshot() async => [
      for (final r in await db.getAllActiveForBackup()) r.toMap(),
    ];
    await BackupService.importBackup(exported, db: db, settings: settings, album: albumWithSavedFiles());
    final first = await snapshot();
    final second = await BackupService.importBackup(exported, db: db, settings: settings, album: albumWithSavedFiles());
    expect(second.insertedPosts, 0);
    expect(await snapshot(), first);
    final exportedAgain = await BackupService.exportBackup(db: db, settings: settings);
    await BackupService.importBackup(exportedAgain, db: db, settings: settings, album: albumWithSavedFiles());
    expect(await snapshot(), first);
  });

  test('a mediaId hint is used only when name and size match', () async {
    BackupData backupWithSize(int size) => BackupData(
      exportedAt: '2026-10-22T10:00:00+08:00',
      settings: BackupSettings(),
      posts: [
        BackupPost(
          platform: 'x',
          sourceId: _xPost,
          originalUrl: 'https://x.com/i/status/$_xPost',
          savedAt: '2026-10-01T09:00:00+08:00',
          files: [
            // Renamed by the system, so neither provenance nor convention.
            BackupFile(itemIndex: 1, mediaType: 'video', filename: 'renamed (1).mp4',
                mediaIdHint: '701', size: size, savedAt: '2026-10-01T09:00:00+08:00'),
          ],
        ),
      ],
    );
    final album = _FakeAlbum([
      (asset: _asset('701', 'renamed (1).mp4', video: true), prov: null, size: 4242),
    ]);
    await BackupService.importBackup(jsonEncode(backupWithSize(1).toMap()), db: db, settings: settings, album: album);
    expect((await db.getByPostId(_xPost, platform: 'x'))!.files.single.mediaId, isNull);
    await db.clear();
    await BackupService.importBackup(jsonEncode(backupWithSize(4242).toMap()), db: db, settings: settings, album: album);
    expect((await db.getByPostId(_xPost, platform: 'x'))!.files.single.mediaId, '701');
  });

  test('backup size: v2 against the v1 layout of the same history', () async {
    // 40 posts × 4 images with signed CDN URLs, as in a real history.
    for (var p = 0; p < 40; p++) {
      final id = '6ad2f70500000000120${p.toString().padLeft(5, '0')}';
      await db.upsert(_xhsRecord(id, [
        for (var i = 1; i <= 4; i++)
          _file(id, i, mediaId: '${p * 10 + i}', assetId: 'asset-$p-$i', size: 1000 + i),
      ]));
    }
    final v2 = await BackupService.exportBackup(db: db, settings: settings);
    // The v1 layout: post `items` and a per-file `provenance` with the URL.
    final v1Map = jsonDecode(v2) as Map<String, dynamic>;
    v1Map['formatVersion'] = 1;
    v1Map.remove('schemaVersion');
    for (final r in await db.getAllActiveForBackup()) {
      final post = (v1Map['posts'] as List).cast<Map<String, dynamic>>()
          .firstWhere((p) => p['sourceId'] == r.postId);
      post['items'] = jsonDecode(r.itemsJson!);
      post['createdAt'] = post.remove('savedAt');
      for (final f in (post['files'] as List).cast<Map<String, dynamic>>()) {
        f['mediaId'] = f.remove('mediaIdHint');
        f['provenance'] = {
          'schema': '0.1',
          'assetId': f['assetId'],
          'capturedAt': f['savedAt'],
          'capturedBy': f.remove('capturedBy'),
          'metadataDate': f['savedAt'],
          'source': {'url': post['canonicalUrl'], 'platform': post['platform'], 'id': r.postId,
            'itemIndex': f['itemIndex'], 'itemCount': f.remove('itemCount')},
          'title': r.title,
          'creator': [r.authorName],
        };
        f.remove('size');
      }
      post.remove('canonicalUrl');
      post.remove('status');
    }
    final v1 = const JsonEncoder.withIndent('  ').convert(v1Map);
    final v1Bytes = utf8.encode(v1).length;
    final v2Bytes = utf8.encode(v2).length;
    // ignore: avoid_print
    print('BACKUP_SIZE posts=40 files=160 v1Bytes=$v1Bytes v2Bytes=$v2Bytes '
        'ratio=${(v2Bytes / v1Bytes).toStringAsFixed(2)}');
    expect(v2Bytes, lessThan(v1Bytes));
  });

  test('schema 6 adds download_error to an existing v5 database', () async {
    final dir = await Directory.systemTemp.createTemp('easysave_v6_');
    // HistoryDb keeps the file open; like the other migration tests the
    // temp folder is left to the system.
    final path = '${dir.path}/history.db';
    final old = await openDatabase(path, version: 5, onCreate: (d, _) async {
      await d.execute('CREATE TABLE history_records(id INTEGER PRIMARY KEY AUTOINCREMENT, '
          'platform TEXT NOT NULL, platform_display_name TEXT, post_id TEXT NOT NULL, '
          'author_name TEXT, title TEXT, caption TEXT, ai_label TEXT, ai_label_source TEXT, '
          'thumbnail_url TEXT, post_url TEXT NOT NULL UNIQUE, file_count INTEGER NOT NULL, '
          'created_at INTEGER NOT NULL, items_json TEXT, files_json TEXT, is_deleted INTEGER DEFAULT 0)');
      await d.insert('history_records', {'platform': 'xhs', 'post_id': 'v5',
        'post_url': 'https://www.xiaohongshu.com/explore/v5', 'file_count': 0,
        'created_at': 1, 'files_json': '[]'});
    });
    await old.close();
    HistoryDb.resetInstanceForTesting();
    final migrated = await HistoryDb.instance(dbPath: path);
    expect((await migrated.getByPostId('v5'))!.downloadError, isNull);
    await migrated.upsert(HistoryRecord(platform: 'xhs', postId: 'v5',
        postUrl: 'https://www.xiaohongshu.com/explore/v5', fileCount: 0,
        createdAt: DateTime(2026), files: const [], downloadError: '存储空间不足'));
    expect((await migrated.getByPostId('v5'))!.downloadError, '存储空间不足');
  });
}
