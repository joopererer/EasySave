// Copyright 2026 EasySave. All rights reserved.
// v1.11 升级路径测试：以 v1.10.3 格式数据为起点，升级到 v1.11 后
// 历史、设置、备份恢复与下载批次快照均应可正常读取，无数据丢失；
// 开发者选项默认隐藏，模拟下载失败开关为关闭。
//
// 四类旧数据：
//   1. files_json 中不带 status 字段的旧历史记录；
//   2. 不含 creatorSort / imageFormat / developerOptionsVisible /
//      devSimulatedDownloadFailureArmed / backupFolderName 等新设置的旧
//      SharedPreferences；
//   3. 文件不带 status、设置不带 imageFormat / 自动备份字段的旧备份
//      v2 文件；
//   4. 升级前处于等待中（waitingNetwork）或失败的下载批次快照。

import 'dart:convert';
import 'dart:io';

import 'package:easysave/services/backup/backup_restore_matcher.dart';
import 'package:easysave/services/backup/backup_service.dart';
import 'package:easysave/services/creator_sort.dart';
import 'package:easysave/services/dev_download_failure.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/image_format_preference.dart';
import 'package:easysave/services/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:provenance_dart/provenance_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _postId = '6ad2f7050000000012034042';

class _EmptyAlbum implements RestoreAlbum {
  const _EmptyAlbum();

  @override
  Future<bool> ensureIndexed() async => true;

  @override
  List<AssetEntity> get assets => const [];

  @override
  AssetEntity? byId(String id) => null;

  @override
  Future<XmpProvenance?> provenance(AssetEntity asset) async => null;

  @override
  Future<int?> size(AssetEntity asset) async => null;
}

/// 一条不带 status 字段（也未写 pair_id/undecodable/size 等 v1.11 新字段）
/// 的 v1.10.3 风格 files_json 行。
Map<String, Object?> _oldFileRow(
  int index, {
  String? mediaId,
  bool image = true,
}) =>
    <String, Object?>{
      'filename': '${_postId}_$index.${image ? 'jpg' : 'mp4'}',
      'saved_at': DateTime.utc(2026, 10, 1, 8).millisecondsSinceEpoch,
      if (mediaId != null) 'media_id': mediaId,
      'item_index': index,
      'is_image': image ? 1 : 0,
    };

Future<Database> _seedV1103HistoryDb(String path) async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final db = await openDatabase(
    path,
    version: 7,
    onCreate: (d, _) async {
      await d.execute(
        'CREATE TABLE history_records('
        'id INTEGER PRIMARY KEY AUTOINCREMENT,'
        'platform TEXT NOT NULL,'
        'platform_display_name TEXT,'
        'post_id TEXT NOT NULL,'
        'author_name TEXT,'
        'title TEXT,'
        'caption TEXT,'
        'ai_label TEXT,'
        'ai_label_source TEXT,'
        'thumbnail_url TEXT,'
        'post_url TEXT NOT NULL UNIQUE,'
        'file_count INTEGER NOT NULL,'
        'created_at INTEGER NOT NULL,'
        'items_json TEXT,'
        'files_json TEXT,'
        'is_deleted INTEGER DEFAULT 0,'
        'download_error TEXT)',
      );
    },
  );
  final created = DateTime.utc(2026, 10, 1, 9);
  await db.insert('history_records', {
    'platform': 'xhs',
    'post_id': _postId,
    'author_name': 'Author',
    'title': 'Old note',
    'caption': 'Old caption',
    'thumbnail_url': 'https://cdn/thumb.jpg',
    'post_url': 'https://www.rednote.com/explore/$_postId',
    'file_count': 2,
    'created_at': created.millisecondsSinceEpoch,
    'items_json': jsonEncode([
      {'type': 'image', 'url': 'https://cdn/1.jpg'},
      {'type': 'image', 'url': 'https://cdn/2.jpg'},
    ]),
    // 旧记录：files_json 行不带 status 字段。
    'files_json': jsonEncode([
      _oldFileRow(1, mediaId: '201'),
      _oldFileRow(2, mediaId: '202'),
    ]),
    'is_deleted': 0,
    'download_error': null,
  });
  return db;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('1. 历史：files_json 无 status 的旧记录升级后读取正常，无数据丢失', () {
    late String path;

    setUp(() async {
      HistoryDb.resetInstanceForTesting();
      final dir = await Directory.systemTemp.createTemp('easysave_upgrade_db_');
      path = '${dir.path}/history.db';
      await _seedV1103HistoryDb(path);
    });

    tearDown(() async {
      HistoryDb.resetInstanceForTesting();
      try {
        if (File(path).existsSync()) await File(path).delete();
      } catch (_) {}
    });

    test('旧记录读取后 status 为 unknown，标题、文件与时间全保留', () async {
      final db = await HistoryDb.instance(dbPath: path);
      final record = await db.getByPostId(_postId, platform: 'xhs');
      expect(record, isNotNull);
      expect(record!.title, 'Old note');
      expect(record.authorName, 'Author');
      expect(record.caption, 'Old caption');
      expect(record.fileCount, 2);
      // 旧行没有 status，读取后应回退为 unknown，不崩溃、不丢数据。
      expect(record.files.length, 2);
      expect(record.files[0].status, FileStatus.unknown);
      expect(record.files[1].status, FileStatus.unknown);
      expect(record.files[0].mediaId, '201');
      expect(record.files[1].mediaId, '202');
      expect(record.files[0].itemIndex, 1);
      expect(record.files[1].itemIndex, 2);
      // 没有 items 时的 fallback 总数取最高索引，保持与旧数据一致。
      expect(record.originalItemCount, 2);

      // 重新打开（模拟重装后再次升级读取）结果一致。
      HistoryDb.resetInstanceForTesting();
      final again = await HistoryDb.instance(dbPath: path);
      final againRecord = await again.getByPostId(_postId, platform: 'xhs');
      expect(againRecord!.files.length, 2);
      expect(againRecord.files.every((f) => f.status == FileStatus.unknown),
          isTrue);
    });
  });

  group('2. 设置：旧 SharedPreferences 无新设置项，升级后取默认值', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      DevDownloadFailure.resetForTesting();
    });

    tearDown(() async {
      await DevDownloadFailure.settleForTesting();
      DevDownloadFailure.resetForTesting();
    });

    test('缺失 creatorSort / imageFormat / developerOptionsVisible / '
        'devSimulatedDownloadFailureArmed / backupFolderName 时取默认值', () async {
      // 只写入 v1.10.3 时代已有的设置，不写入 v1.11 新增的任何键。
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('albumName', 'EasySave');
      await prefs.setBool('bubbleEnabled', false);
      await prefs.setString('historyView', 'posts');
      await prefs.setString('historyLayout', 'waterfall');
      await prefs.setString('historySort', 'latest');

      final settings = await AppSettings.load();

      // 新增设置项全部取默认值，不因旧数据缺失而异常。
      expect(settings.imageFormat, ImageFormatPreference.compat);
      expect(settings.creatorSort, CreatorSort.latestSaved);
      expect(settings.creatorSortDescending, isTrue);
      expect(settings.developerOptionsVisible, isFalse,
          reason: '开发者选项对普通用户默认隐藏');
      expect(settings.backupFolderName, isNull);
      expect(settings.backupTreeUri, isNull);
      expect(settings.autoFolderBackupEnabled, isFalse);

      // 模拟失败开关：旧偏好中没有 devSimulatedDownloadFailureArmed，
      // 读取后必须为关闭。
      await DevDownloadFailure.refresh();
      expect(DevDownloadFailure.armed, isFalse,
          reason: '模拟下载失败开关升级后应为关闭');
    });
  });

  group('3. 备份：旧 v2 备份无 status / imageFormat / 自动备份字段，恢复正常', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      HistoryDb.resetInstanceForTesting();
    });

    tearDown(() => HistoryDb.resetInstanceForTesting());

    test('缺失文件 status 与设置 imageFormat / 自动备份字段的 v2 备份可导入', () async {
      final db = await HistoryDb.instance(dbPath: ':memory:');
      HistoryDb.setInstanceForTesting(db);
      await db.clear();
      final settings = await AppSettings.load();
      BackupService.mediaSizesReader = (_) async => const {};
      addTearDown(() => BackupService.mediaSizesReader = null);

      final backup = jsonEncode({
        'format': 'easysave-backup',
        'schemaVersion': 2,
        'formatVersion': 2,
        'exportedAt': '2026-10-20T10:00:00+08:00',
        'appVersion': '1.10.3',
        'provenanceSpecVersion': '1.0',
        // 旧备份不写 imageFormat 与自动备份字段。
        'settings': {'albumName': 'EasySave'},
        'posts': [
          {
            'platform': 'xiaohongshu',
            'sourceId': _postId,
            'originalUrl': 'https://www.rednote.com/explore/$_postId?xsec_token=OLD',
            'title': 'Old note',
            'authorName': 'Old author',
            'savedAt': '2026-10-01T09:00:00+08:00',
            'status': 'success',
            'files': [
              {
                'itemIndex': 1,
                'mediaType': 'image',
                'filename': '${_postId}_1.jpg',
                'relativePath': 'Pictures/EasySave/',
                'savedAt': '2026-10-01T09:00:00+08:00',
                'mediaIdHint': '201',
                // 旧备份文件不带 status 字段，读取后视为 unknown。
              },
            ],
          },
        ],
      });

      // 预览不应崩溃，且识别出一篇一项。
      final preview = BackupService.previewBackup(backup);
      expect(preview.postCount, 1);
      expect(preview.fileCount, 1);
      expect(preview.settings!.imageFormat, 'compat');

      final result = await BackupService.importBackup(
        backup,
        db: db,
        settings: settings,
        album: const _EmptyAlbum(),
      );
      expect(result.restoredPosts, 1);

      final restored = await db.getByPostId(_postId, platform: 'xiaohongshu');
      expect(restored, isNotNull);
      expect(restored!.title, 'Old note');
      expect(restored.authorName, 'Old author');
      expect(restored.files.length, 1);
      // 无 status 的旧文件在本设备找不到匹配，记为不在本机，保留条目不丢失。
      expect(restored.files.single.status, FileStatus.notFound);

      // 备份中的设置字段缺失时取默认值，不把自动备份意外打开。
      final reloaded = await AppSettings.load();
      expect(reloaded.imageFormat, ImageFormatPreference.compat);
      expect(reloaded.backupFolderName, isNull);
      expect(reloaded.autoFolderBackupEnabled, isFalse);
    });
  });

  group('4. 下载批次快照：升级前等待中或失败的快照可反序列化', () {
    setUp(() {
      DownloadManager.instance.clearBatchesForTesting();
    });

    tearDown(() {
      DownloadManager.instance.clearBatchesForTesting();
    });

    // 旧快照由 liveBatches() 从 SharedPreferences 读取后经 DownloadBatch.fromJson
    // 反序列化；此处直接驱动 fromJson，等价于验证升级后读取旧快照的兼容性。
    DownloadBatch batchFromOldSnapshot(Map<String, dynamic> json) =>
        DownloadBatch.fromJson(json.cast<String, Object?>());

    test('等待网络批次的旧快照反序列化后状态保留，新字段取默认', () async {
      final waitingJson = {
        'batchId': 'batch-waiting',
        'album': 'EasySave',
        'postUrl': 'https://www.rednote.com/explore/$_postId',
        'platform': 'xhs',
        'postId': _postId,
        'authorName': 'Author',
        'title': 'Waiting note',
        'itemsJson': jsonEncode([
          {'type': 'image', 'url': 'https://cdn/1.jpg'},
          {'type': 'image', 'url': 'https://cdn/2.jpg'},
        ]),
        'jobs': [
          {
            'key': 'k1',
            'label': '图片 1',
            'filename': '${_postId}_1.jpg',
            'urls': ['https://cdn/1.jpg'],
            'isImage': true,
            'itemIndex': 1,
            'state': 6, // JobState.waitingNetwork
            'attempts': 0,
            'saved': false,
          },
          {
            'key': 'k2',
            'label': '图片 2',
            'filename': '${_postId}_2.jpg',
            'urls': ['https://cdn/2.jpg'],
            'isImage': true,
            'itemIndex': 2,
            'state': 6, // JobState.waitingNetwork
            'attempts': 0,
            'saved': false,
          },
        ],
        'historyWritten': false,
        'startedAt': DateTime.utc(2026, 10, 1).millisecondsSinceEpoch,
      };
      // 刻意不写 formatPref / postItemCount / jpegFallback / source / settledBy
      // 等 v1.11 新增字段。

      final waiting = batchFromOldSnapshot(waitingJson);
      expect(waiting.waitingForNetwork, isTrue,
          reason: '等待网络的批次升级后仍应处于等待');
      expect(waiting.isTerminal, isFalse);
      // 旧快照不写 formatPref，读取后回退为兼容优先。
      expect(waiting.formatPref, ImageFormatPreference.compat);
      expect(waiting.postItemCount, isNull);
      expect(waiting.source, DownloadBatch.sourceMain);
      expect(waiting.itemTotal, 2);
    });

    test('失败批次的旧快照反序列化后失败项与原因保留，新字段取默认', () async {
      final failedJson = {
        'batchId': 'batch-failed',
        'album': 'EasySave',
        'postUrl': 'https://www.rednote.com/explore/$_postId',
        'platform': 'xhs',
        'postId': _postId,
        'authorName': 'Author',
        'title': 'Failed note',
        'itemsJson': jsonEncode([{'type': 'image', 'url': 'https://cdn/1.jpg'}]),
        'jobs': [
          {
            'key': 'k1',
            'label': '图片 1',
            'filename': '${_postId}_1.jpg',
            'urls': ['https://cdn/1.jpg'],
            'isImage': true,
            'itemIndex': 1,
            'state': 3, // JobState.failed
            'attempts': 3,
            'saved': false,
            'error': '网络错误',
          },
        ],
        'historyWritten': true,
        'startedAt': DateTime.utc(2026, 10, 1).millisecondsSinceEpoch,
      };

      final failed = batchFromOldSnapshot(failedJson);
      expect(failed.failedCount, 1);
      // 原始错误随快照保留；failureReason 会按固定原因集归一化，此处只
      // 断言失败已被读取且不为空。
      expect(failed.jobs.single.error, '网络错误');
      expect(failed.failureReason, isNotNull);
      expect(failed.formatPref, ImageFormatPreference.compat);
      expect(failed.postItemCount, isNull);
      expect(failed.jobs.single.state, JobState.failed);
    });
  });
}
