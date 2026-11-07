import 'dart:convert';

import 'package:easysave/pages/history_page.dart';
import 'package:easysave/services/backup/backup_model.dart';
import 'package:easysave/services/backup/backup_restore_matcher.dart';
import 'package:easysave/services/backup/backup_service.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/settings.dart';
import 'package:easysave/widgets/history_cards.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:provenance_dart/provenance_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _EmptyAlbum implements RestoreAlbum {
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  for (final (reason, label) in [
    (null, '下载失败，点击重试'),
    ('HTTP 403', '下载失败（HTTP 403），点击重试'),
  ]) {
    testWidgets('a failed post restored from a v2 backup shows "$label"',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      HistoryDb.resetInstanceForTesting();
      GalleryLocatorService.instance.resetForTesting();
      DownloadManager.instance.clearBatchesForTesting();
      const photos = MethodChannel('com.fluttercandies/photo_manager');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        photos,
        (_) async => 0,
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(photos, null);
        GalleryLocatorService.instance.resetForTesting();
        HistoryDb.resetInstanceForTesting();
      });

      const id = '6ad2f7050000000012034042';
      final backup = jsonEncode(BackupData(
        exportedAt: '2026-11-07T10:00:00+01:00',
        settings: BackupSettings(),
        posts: [
          BackupPost(
            platform: 'xiaohongshu',
            sourceId: id,
            canonicalUrl: 'https://www.xiaohongshu.com/explore/$id',
            originalUrl: 'https://www.xiaohongshu.com/explore/$id?xsec_token=T',
            title: 'Restored failure',
            savedAt: '2026-11-07T09:00:00+01:00',
            status: BackupPostStatus.failed,
            failureReason: reason,
            files: const [],
          ),
        ],
      ).toMap());
      await tester.runAsync(() async {
        final db = await HistoryDb.instance(dbPath: ':memory:');
        HistoryDb.setInstanceForTesting(db);
        await db.clear();
        await BackupService.importBackup(backup,
            db: db, settings: AppSettings(), album: _EmptyAlbum());
      });

      await tester.pumpWidget(const MaterialApp(home: HistoryPage()));
      for (var i = 0; i < 12; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }

      expect(find.text('Restored failure'), findsOneWidget);
      expect(find.text(label), findsOneWidget);
      final overlay = tester.widget<DownloadingOverlay>(find.byType(DownloadingOverlay));
      expect(overlay.failed, isTrue);
      expect(overlay.onTogglePause, isNotNull,
          reason: 'retry re-parses the original link');
    });
  }
}
