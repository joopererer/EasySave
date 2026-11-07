import 'dart:convert';
import 'dart:io';

import 'package:easysave/metadata/provenance_version.dart';
import 'package:easysave/metadata/site_provenance.dart';
import 'package:easysave/metadata/url_normalizer.dart';
import 'package:easysave/services/clipboard_guard.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/save_collision.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _id = '6ad2f7050000000012034042';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  final vectors = (jsonDecode(
    File('../docs/provenance-spec/test-vectors/urls-0.1.8.json').readAsStringSync(),
  ) as Map)['cases'] as List;

  test('the App depends on provenance-spec 0.1.8', () {
    expect(provenanceSpecVersion, '0.1.8');
  });

  test('normalizeUrl passes every urls-0.1.8 vector', () {
    for (final c in vectors.cast<Map>()) {
      expect(normalizeUrl(c['in'] as String), c['out'], reason: c['in'] as String);
    }
  });

  test('App canonical URL and sourceId agree with the spec for every valid '
      'Xiaohongshu note vector', () {
    for (final c in vectors.cast<Map>().where((c) => c['id'] != null)) {
      final input = c['in'] as String;
      expect(SiteRegistry.current.canonicalUrl(input), c['out'], reason: input);
      expect(postIdOfUrl(input), c['id'], reason: input);
    }
  });

  test('rednote and xiaohongshu links of one note are the same post', () {
    final links = [
      'https://www.xiaohongshu.com/explore/$_id?xsec_token=T&xsec_source=pc_feed',
      'https://xiaohongshu.com/discovery/item/$_id',
      'https://www.rednote.com/explore/$_id?xsec_token=T',
      'https://rednote.com/user/profile/5f1a2b3c000000000100abcd/$_id',
    ];
    final canonicals = links.map((l) => SiteRegistry.current.canonicalUrl(l)).toSet();
    expect(canonicals, {'https://www.xiaohongshu.com/explore/$_id'});
    expect(links.map(postIdOfUrl).toSet(), {_id});
    expect(links.map(canonicalForComparison).toSet(),
        {'https://www.xiaohongshu.com/explore/$_id'});

    dynamic provenance(String url) => buildSiteProvenance(
      platform: 'xhs',
      capturedBy: 'EasySave',
      sourceId: postIdOfUrl(url)!,
      sourceUrl: url,
      itemIndex: 1,
      itemCount: 1,
    );
    final fromRednote = provenance(links[2]);
    final fromXhs = provenance(links[0]);
    expect(fromRednote.sourceUrl, 'https://www.xiaohongshu.com/explore/$_id');
    expect(fromRednote.sourceUrl, fromXhs.sourceUrl);
    expect(sameSavedOrigin(fromRednote, fromXhs), isTrue);
  });

  test('an old rednote canonical is matched by re-normalizing, never rewritten',
      () async {
    const old = 'https://www.rednote.com/explore/$_id';
    expect(
      isLinkKnown('https://www.xiaohongshu.com/explore/$_id?xsec_token=T',
          [(postUrl: old, postId: 'legacy-row')]),
      isTrue,
    );
    HistoryDb.resetInstanceForTesting();
    final db = await HistoryDb.instance(dbPath: ':memory:');
    HistoryDb.setInstanceForTesting(db);
    addTearDown(HistoryDb.resetInstanceForTesting);
    await db.clear();
    await db.upsert(HistoryRecord(
      platform: 'xhs',
      postId: 'legacy-row',
      postUrl: old,
      fileCount: 0,
      createdAt: DateTime(2026),
      files: const [],
    ));
    final found = await db.findRecordByLink(
        'https://www.xiaohongshu.com/discovery/item/$_id');
    expect(found?.postId, 'legacy-row');
    expect(found?.postUrl, old, reason: 'the stored value is not rewritten');
    expect((await db.getByPostId('legacy-row'))!.postUrl, old);
  });
}

