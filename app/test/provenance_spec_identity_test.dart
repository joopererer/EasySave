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

/// Every released normalization vector file the App must satisfy. 0.1.9 is a
/// purely additive release (Douyin vectors); the App only enables the site
/// rules it ships, so the Douyin cases are checked against the package's
/// normalization, not against the App's site registry.
const _vectorFiles = ['urls-0.1.8.json', 'urls-0.1.9.json'];

List<Map> _readVectors() => [
  for (final name in _vectorFiles)
    ...((jsonDecode(
              File('../docs/provenance-spec/test-vectors/$name').readAsStringSync(),
            ) as Map)['cases']
            as List)
        .cast<Map>(),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  final vectors = _readVectors();

  test('the App depends on provenance-spec 0.1.9', () {
    expect(provenanceSpecVersion, '0.1.9');
  });

  test('normalizeUrl passes every released vector (0.1.8 and 0.1.9)', () {
    for (final c in vectors) {
      expect(normalizeUrl(c['in'] as String), c['out'], reason: c['in'] as String);
    }
  });

  test('the 0.1.9 release is additive: every previous vector is unchanged', () {
    final previous = {
      for (final c in (jsonDecode(
                File('../docs/provenance-spec/test-vectors/urls-0.1.8.json')
                    .readAsStringSync(),
              ) as Map)['cases']
              as List)
        (c as Map)['in'] as String: c['out'] as String,
    };
    final current = {
      for (final c in vectors) c['in'] as String: c['out'] as String,
    };
    previous.forEach((input, out) => expect(current[input], out, reason: input));
  });

  test('App canonical URL and sourceId agree with the spec for every valid '
      'Xiaohongshu note vector', () {
    final xhs = vectors.where(
      (c) => c['id'] != null && c['platform'] == 'xiaohongshu',
    );
    expect(xhs, isNotEmpty);
    for (final c in xhs) {
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
