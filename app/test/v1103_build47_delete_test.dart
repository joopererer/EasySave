// v1.10.3 build 47 — deleting two posts.
//
// The device report: selecting 6af1ad13 (3 files) and 6af3c278 (4 files), the
// sheet offered "1 个文件", ticking the box deleted nothing from the album, and
// one of the two posts stayed on the history page — still openable — until the
// page was left.
//
// Three separate rules are pinned here:
//  * the sheet offers the real number of saved files, not only the rows that
//    already carry a located album id;
//  * asking to delete the album files resolves their current ids first, so the
//    request names every file (and says so when it cannot);
//  * a post this page deleted never comes back from a snapshot read that was
//    already in flight.

import 'dart:io';

import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/history_deletion.dart';
import 'package:easysave/services/media_delete_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _postA = '6af1ad13000000003400572d';
const _postB = '6af3c278000000001c031f21';

HistoryFile _file(int index, {String? mediaId, FileStatus? status}) =>
    HistoryFile(
      filename: '${_postA}_$index.jpg',
      savedAt: 1700000000000 + index,
      mediaId: mediaId,
      itemIndex: index,
      status: status ?? FileStatus.unknown,
    );

HistoryRecord _record(String postId, List<HistoryFile> files, {int? id}) =>
    HistoryRecord(
      id: id,
      platform: 'xhs',
      postId: postId,
      postUrl: 'https://www.xiaohongshu.com/explore/$postId',
      fileCount: files.length,
      createdAt: DateTime(2026, 1, 1),
      files: files,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late String tempDbPath;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    final dir = await Directory.systemTemp.createTemp('easysave_delete47_');
    tempDbPath = '${dir.path}/history.db';
    HistoryDb.resetInstanceForTesting();
    GalleryLocatorService.instance.resetForTesting();
    await HistoryDb.instance(dbPath: tempDbPath);
  });

  tearDown(() async {
    HistoryDb.resetInstanceForTesting();
    GalleryLocatorService.instance.resetForTesting();
    try {
      final file = File(tempDbPath);
      final dir = file.parent;
      if (await file.exists()) await file.delete();
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  });

  test('the sheet counts every saved file of the selected posts', () {
    final a = _record(_postA, [
      _file(1, mediaId: '101'),
      _file(2, mediaId: '102'),
      _file(3, mediaId: '103'),
    ]);
    final b = _record(_postB, [
      _file(1, mediaId: '201'),
      _file(2, mediaId: '202'),
      _file(3, mediaId: '203'),
      _file(4, mediaId: '204'),
    ]);
    expect(savedFileCountFor([a, b]), 7);
    // Rows without an id are still files the user saved.
    expect(savedFileCountFor([_record(_postA, [_file(1), _file(2)])]), 2);
    // The old count only saw rows already located in the album.
    expect(deletableMediaFor([a, b]), isEmpty);
  });

  test('asking to delete the album files resolves the ids first', () async {
    final files = [
      _file(1, mediaId: '101'),
      _file(2, mediaId: '102'),
      _file(3, mediaId: '103'),
    ];
    final record = _record(_postA, files);
    // The album holds all three, under the same ids.
    GalleryLocatorService.instance.setScannedForTesting(
      scanned: true,
      permission: PermissionState.authorized,
      assets: [
        for (final file in files)
          AssetEntity(
            id: file.mediaId!,
            typeInt: AssetType.image.index,
            width: 100,
            height: 100,
            title: file.filename,
            relativePath: 'Pictures/EasySave/',
          ),
      ],
    );
    GalleryLocatorService.instance.presenceProbeForTesting = (_) async => true;

    final media = await resolveDeletableMedia([record]);
    expect(media.map((m) => m.mediaId), ['101', '102', '103']);
    expect(media.every((m) => m.isImage), isTrue);
    // The rows are now linked, so the request really names the album files.
    expect(record.files.every((f) => f.status == FileStatus.found), isTrue);
  });

  test('an approved delete that left files behind says so', () {
    const all = MediaDeleteOutcome(approved: true, requested: 3);
    expect(all.deletedAll, isTrue);
    expect(all.problem, isNull);

    const declined = MediaDeleteOutcome(approved: false, requested: 3);
    expect(declined.deletedAll, isFalse);
    expect(declined.problem, contains('未删除'));

    const partial = MediaDeleteOutcome(
      approved: true,
      requested: 3,
      remaining: 2,
    );
    expect(partial.deletedAll, isFalse);
    expect(partial.problem, contains('2'));
  });

  test('a deleted post never comes back from an in-flight snapshot', () {
    final a = _record(_postA, [_file(1, mediaId: '101')], id: 200);
    final b = _record(_postB, [_file(1, mediaId: '201')], id: 199);
    final other = _record('6af000000000000000000000', [_file(1)], id: 198);

    // Delete both by id.
    final afterIds = dropDeletedRecords(
      [a, b, other],
      ids: {200, 199},
    );
    expect(afterIds.map((r) => r.id), [198]);

    // The other engine wrote a new row for the same post: the post key still
    // keeps it off the page.
    final rewritten = _record(_postA, [_file(1, mediaId: '101')], id: 4242);
    final afterKeys = dropDeletedRecords(
      [rewritten, other],
      postKeys: {postKeyOf(a), postKeyOf(b)},
    );
    expect(afterKeys.map((r) => r.id), [198]);
    expect(postKeyOf(a), 'xhs:$_postA');
  });
}
