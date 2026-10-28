import 'dart:io';
import 'package:easysave/core/models.dart';
import 'package:easysave/services/clipboard_guard.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/links.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const id = '7674898126922140959';
  const short = 'https://vm.tiktok.com/FAKE/';
  const canonical = 'https://www.tiktok.com/@/video/$id';
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  test(
    'short-link identity survives database reopening but does not suppress unsaved or deleted posts',
    () async {
      final dir = await Directory.systemTemp.createTemp('recent_tiktok_');
      final path = '${dir.path}/history.db';
      var db = await HistoryDb.instance(dbPath: path);
      addTearDown(() async {
        await (await databaseFactory.openDatabase(path)).close();
        HistoryDb.resetInstanceForTesting();
        await dir.delete(recursive: true);
      });
      final post = ParsedPost(
        platform: 'tiktok',
        id: id,
        url: canonical,
        author: PostAuthor(),
        items: [],
      );
      await db.rememberParsedLink(short, post);
      expect(await db.findRecordByLink(short), isNull); // Parsed, never saved.
      await db.upsert(
        HistoryRecord(
          platform: 'tiktok',
          postId: id,
          postUrl: canonical,
          fileCount: 1,
          createdAt: DateTime.now(),
        ),
      );
      await (await databaseFactory.openDatabase(path)).close();
      HistoryDb.resetInstanceForTesting();
      db = await HistoryDb.instance(dbPath: path);
      final saved = await db.findRecordByLink('$short?tracking=FAKE');
      expect(saved?.postId, id);
      expect(await db.findRecordByLink('https://vm.tiktok.com/OTHER/'), isNull);
      await db.delete(saved!.id!);
      expect(await db.findRecordByLink(short), isNull);
    },
  );
  test(
    'TikTok photo and alternate long forms match downloaded canonical video identity',
    () {
      const records = [(postUrl: canonical, postId: id)];
      for (final path in [
        '/@someone/photo/$id',
        '/share/video/$id',
        '/v/$id.html',
      ]) {
        expect(
          isLinkKnown('https://www.tiktok.com$path?tracking=FAKE', records),
          isTrue,
        );
      }
    },
  );
  test(
    'history lookup expands vm and vt while parsing still leaves them for WebView',
    () async {
      for (final host in ['vm.tiktok.com', 'vt.tiktok.com']) {
        final link = 'https://$host/FAKE/';
        var calls = 0;
        Future<String?> redirect(Uri uri) async {
          calls++;
          return uri.host == host
              ? 'https://www.tiktok.com/@someone/photo/$id?tracking=FAKE'
              : null;
        }

        expect(await resolveShortLink(link, readRedirect: redirect), link);
        expect(calls, 0);
        final resolved = await resolveShortLink(
          link,
          forHistoryLookup: true,
          readRedirect: redirect,
        );
        expect(
          isLinkKnown(link, [
            (postUrl: canonical, postId: id),
          ], resolvedUrl: resolved),
          isTrue,
        );
        expect(calls, 2);
      }
    },
  );
}
