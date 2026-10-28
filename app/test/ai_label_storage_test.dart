import 'dart:convert';
import 'dart:io';

import 'package:easysave/core/models.dart';
import 'package:easysave/metadata/metadata_service.dart';
import 'package:easysave/services/backup/backup_service.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const labelText = '作者声明：含 ai 生成内容  ';
DownloadBatch batch({String? text = labelText}) => DownloadBatch(
  batchId: 'ai', album: 'EasySave', platform: 'xhs', postId: '123',
  postUrl: 'https://www.xiaohongshu.com/explore/123', jobs: [],
  aiLabel: text, aiLabelSource: text == null ? null : 'author', postItemCount: 2,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() { sqfliteFfiInit(); databaseFactory = databaseFactoryFfi; });
  setUp(() { SharedPreferences.setMockInitialValues({}); HistoryDb.resetInstanceForTesting(); });

  test('parsed label survives serialization without trimming', () {
    final post = ParsedPost.fromJson({
      'platform': 'xhs', 'id': '123', 'url': 'https://example.invalid', 'items': [],
      'aiLabel': {'text': labelText, 'source': 'author'},
    });
    expect(ParsedPost.fromJson(post.toJson()).aiLabel?.text, labelText);
    expect(AiLabel.fromJson({'text': 'AI', 'source': 'unexpected'}), isNull);
  });

  test('batch snapshot and engine adoption preserve label', () {
    final restored = DownloadBatch.fromJson(batch().toJson()).copyOwnedBy('background');
    expect(restored.aiLabel, labelText);
    expect(restored.aiLabelSource, 'author');
    expect(provenanceForBatchItem(batch(text: null), itemIndex: 1).digitalSourceType, isNull);
  });

  for (final filename in ['no-metadata.jpg', 'mp4-no-xmp.mp4']) {
    test('all items write verbatim AI metadata to $filename', () async {
      final dir = await Directory.systemTemp.createTemp('ai_metadata_');
      addTearDown(() => dir.delete(recursive: true));
      for (var index = 1; index <= 2; index++) {
        final file = await File('../docs/provenance-spec/test-vectors/$filename')
            .copy('${dir.path}/${index}_$filename');
        final provenance = provenanceForBatchItem(batch(), itemIndex: index);
        await MetadataService.embedProvenance(filePath: file.path, provenance: provenance);
        final read = await MetadataService.readProvenance(file.path);
        expect(read?.aiLabel, labelText);
        expect(read?.aiLabelSource, 'author');
        expect(read?.digitalSourceType, 'http://cv.iptc.org/newscodes/digitalsourcetype/compositeWithTrainedAlgorithmicMedia');
        expect(read?.itemIndex, index);
      }
    });
  }

  test('v3 migration leaves old rows null and preserves history', () async {
    final dir = await Directory.systemTemp.createTemp('ai_migration_');
    final path = '${dir.path}/history.db';
    final old = await openDatabase(path, version: 3, onCreate: (db, _) async {
      await db.execute('CREATE TABLE history_records(id INTEGER PRIMARY KEY AUTOINCREMENT, platform TEXT NOT NULL, post_id TEXT NOT NULL, author_name TEXT, title TEXT, caption TEXT, thumbnail_url TEXT, post_url TEXT NOT NULL UNIQUE, file_count INTEGER NOT NULL, created_at INTEGER NOT NULL, items_json TEXT, files_json TEXT, is_deleted INTEGER DEFAULT 0)');
      await db.insert('history_records', {'platform': 'xhs', 'post_id': 'old', 'post_url': 'https://example.invalid/old', 'file_count': 0, 'created_at': 1});
    });
    await old.close();
    final db = await HistoryDb.instance(dbPath: path);
    final row = (await db.getByPostId('old'))!;
    expect(row.aiLabel, isNull);
    expect(row.aiLabelSource, isNull);
    expect(row.createdAt.millisecondsSinceEpoch, 1);
    await writePlaceholderHistory(db, batch());
    expect((await db.getByPostId('123'))?.toPost().aiLabel?.text, labelText);
    await writeBatchHistory(db, batch(), recovered: false);
    expect((await db.getByPostId('123'))?.aiLabelSource, 'author');
  });

  test('backup v1 round trip keeps AI fields and accepts old backups', () async {
    final dir = await Directory.systemTemp.createTemp('ai_backup_');
    final db = await HistoryDb.instance(dbPath: '${dir.path}/history.db');
    await writePlaceholderHistory(db, batch());
    final settings = AppSettings();
    final encoded = await BackupService.exportBackup(db: db, settings: settings);
    final data = jsonDecode(encoded) as Map<String, dynamic>;
    expect(data['formatVersion'], 1);
    expect(data['posts'][0]['aiLabel'], labelText);
    expect(data['posts'][0]['aiLabelSource'], 'author');
    await db.clear();
    await BackupService.importBackup(encoded, db: db, settings: settings, restoreSettings: false);
    expect((await db.getByPostId('123'))?.aiLabel, labelText);
    await db.clear();
    (data['posts'][0] as Map).remove('aiLabel');
    (data['posts'][0] as Map).remove('aiLabelSource');
    await BackupService.importBackup(jsonEncode(data), db: db, settings: settings, restoreSettings: false);
    expect((await db.getByPostId('123'))?.aiLabel, isNull);
  });
}
