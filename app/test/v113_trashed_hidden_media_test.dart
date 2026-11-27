import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:easysave/core/dev_log.dart';
import 'package:easysave/core/models.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/widgets/gallery_browser.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const mediaChannel = MethodChannel('easysave/media');
  late Directory tempDir;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('easysave_v113_trash_');
    HistoryDb.resetInstanceForTesting();
    await HistoryDb.instance(dbPath: p.join(tempDir.path, 'history.db'));
    GalleryLocatorService.instance.resetForTesting();
    DownloadManager.instance.clearBatchesForTesting();
    DevLog.resetRecentForTesting();
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(mediaChannel, null);
    GalleryLocatorService.instance.resetForTesting();
    DownloadManager.instance.clearBatchesForTesting();
    HistoryDb.resetInstanceForTesting();
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  Future<void> runRedownloadScenario({
    required String staleId,
    required String freshId,
    required String freshTitle,
    required String staleRelPath,
    required Map<String, dynamic> Function(String id) checkPresentResponse,
  }) async {
    const postId = '6b08096e000000002a019d88';
    final locator = GalleryLocatorService.instance;
    final dm = DownloadManager.instance;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(mediaChannel, (call) async {
      if (call.method == 'checkMediaPresent') {
        final id = (call.arguments as Map)['id']?.toString() ?? '';
        return checkPresentResponse(id);
      }
      if (call.method == 'mediaSize') {
        final id = (call.arguments as Map)['id']?.toString() ?? '';
        return id == freshId ? 2048 : 0;
      }
      return null;
    });

    final staleAsset = AssetEntity(
      id: staleId,
      typeInt: AssetType.video.index,
      width: 1080,
      height: 1920,
      title: '${postId}_1.mp4',
      relativePath: staleRelPath,
    );
    final freshAsset = AssetEntity(
      id: freshId,
      typeInt: AssetType.video.index,
      width: 1080,
      height: 1920,
      title: freshTitle,
      relativePath: 'Movies/EasySave/',
    );

    // 1. Before re-download: stale record exists in index, but isPresent must reject it.
    locator.hasAccessForTesting = true;
    locator.albumReaderForTesting = () async => [staleAsset];
    locator.setScannedForTesting(
      scanned: true,
      permission: PermissionState.authorized,
      assets: [staleAsset],
      relativePaths: {staleId: staleRelPath},
    );

    final batchItems = [MediaItem(type: 'video', url: 'https://cdn.example/v.mp4')];
    final batch = DownloadBatch(
      batchId: 'b_$staleId',
      platform: 'xhs',
      postId: postId,
      postUrl: 'https://www.xiaohongshu.com/explore/$postId',
      authorName: 'author',
      title: 'video post',
      album: 'EasySave',
      jobs: [
        DownloadJob(
          key: 'j_$staleId',
          itemIndex: 1,
          isImage: false,
          label: 'video',
          filename: '${postId}_1.mp4',
          urls: const ['https://cdn.example/v.mp4'],
        ),
      ],
    );

    final existing = await dm.findExistingAlbumAssetForTesting(batch, batch.jobs.first);
    expect(existing, isNull, reason: 'stale record $staleId must not be associated');

    // 2. Simulate re-download completing with a new MediaStore ID (even if renamed "(1)").
    batch.jobs.first
      ..mediaId = freshId
      ..savedTitle = freshTitle
      ..relativePath = 'Movies/EasySave/'
      ..state = JobState.done
      ..saved = true;

    locator.setScannedForTesting(
      scanned: true,
      permission: PermissionState.authorized,
      assets: [freshAsset],
      relativePaths: {freshId: 'Movies/EasySave/'},
    );

    final record = HistoryRecord(
      platform: 'xhs',
      postId: postId,
      postUrl: batch.postUrl,
      fileCount: 1,
      createdAt: DateTime.now(),
      itemsJson: '[{"type":"video","url":"https://cdn.example/v.mp4"}]',
      files: [
        HistoryFile(
          itemIndex: 1,
          isImage: false,
          filename: freshTitle,
          mediaId: freshId,
          relativePath: 'Movies/EasySave/',
          savedAt: DateTime.now().millisecondsSinceEpoch,
          status: FileStatus.found,
        ),
      ],
    );

    final browser = await savedBrowserItems(
      record: record,
      files: record.files,
      post: ParsedPost(
        platform: 'xhs',
        id: postId,
        url: batch.postUrl,
        author: PostAuthor(name: 'author'),
        items: batchItems,
      ),
      albumScanned: true,
    );

    expect(browser.items, hasLength(1));
    expect(browser.items.first.type, 'video');
    expect(browser.items.first.missing, isFalse);
    expect(browser.items.first.asset?.id, freshId);
    expect(await locator.isPresent(freshId), isTrue);
  }

  test('same-name trashed record is ignored and re-downloaded to new mediaId', () async {
    await runRedownloadScenario(
      staleId: 'trashed_101',
      freshId: 'fresh_201',
      freshTitle: '6b08096e000000002a019d88_1 (1).mp4',
      staleRelPath: 'Movies/EasySave/',
      checkPresentResponse: (id) => id == 'fresh_201'
          ? {'present': true}
          : {'present': false, 'reason': 'media_exists_false'},
    );
    expect(
      DevLog.recentLines(20).any((l) => l.contains('is_present_false reason=media_exists_false')),
      isTrue,
    );
  });

  test('same-name pending residual is ignored and re-downloaded to new mediaId', () async {
    await runRedownloadScenario(
      staleId: 'pending_102',
      freshId: 'fresh_202',
      freshTitle: '6b08096e000000002a019d88_1.mp4',
      staleRelPath: 'Movies/EasySave/',
      checkPresentResponse: (id) => id == 'fresh_202'
          ? {'present': true}
          : {'present': false, 'reason': 'media_exists_false'},
    );
  });

  test('same-name unopenable record is ignored and re-downloaded to new mediaId', () async {
    await runRedownloadScenario(
      staleId: 'unopenable_103',
      freshId: 'fresh_203',
      freshTitle: '6b08096e000000002a019d88_1.mp4',
      staleRelPath: 'Movies/EasySave/',
      checkPresentResponse: (id) => id == 'fresh_203'
          ? {'present': true}
          : {'present': false, 'reason': 'open_failed:FileNotFoundException'},
    );
    expect(
      DevLog.recentLines(20).any(
        (l) => l.contains('is_present_false reason=open_failed:FileNotFoundException'),
      ),
      isTrue,
    );
  });

  test('same-name record in hidden MIUI trash directory is ignored and re-downloaded', () async {
    await runRedownloadScenario(
      staleId: 'hidden_104',
      freshId: 'fresh_204',
      freshTitle: '6b08096e000000002a019d88_1.mp4',
      staleRelPath: 'MIUI/Gallery/cloud/.trashBin/EasySave/',
      checkPresentResponse: (id) => id == 'fresh_204'
          ? {'present': true}
          : {'present': false, 'reason': 'media_exists_false'},
    );
  });

  test('diagnoseMediaDup logs rel_dir and is_hidden for trashed and hidden records', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(mediaChannel, (call) async {
      if (call.method == 'diagnoseMediaDup') {
        return [
          {
            'id_hash': 'abcd1234',
            'is_row_media_id': 'y',
            'is_trashed': 1,
            'is_pending': 0,
            'owner': 'self',
            'rel_dir': 'MIUI/Gallery',
            'is_hidden': 1,
            'size': 0,
            'date_added_age_s': 120,
          },
        ];
      }
      return null;
    });

    final rows = await GalleryLocatorService.instance.diagnoseMediaDup(
      '6b08096e000000002a019d88',
      rowMediaId: '999',
    );
    expect(rows, hasLength(1));
    expect(
      DevLog.recentLines(10).any(
        (l) =>
            l.contains('media_dup') &&
            l.contains('rel_dir=MIUI/Gallery') &&
            l.contains('is_hidden=1') &&
            l.contains('is_trashed=1'),
      ),
      isTrue,
    );
  });
}
