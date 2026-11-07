import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:provenance_dart/provenance_dart.dart' show normalizeUrl;
import 'package:easysave/services/site_registry.dart';
import 'package:easysave/metadata/site_provenance.dart';
import 'package:easysave/services/save_collision.dart';

void main() {
  final sites =
      jsonDecode(File('../config/sites.json').readAsStringSync()) as List;
  for (final site in sites.cast<Map>()) {
    test('canonicalTemplate remains stable for ${site['id']}', () {
      final rule = site['normalize'] as Map;
      final url = (rule['canonicalTemplate'] as String).replaceAll(
        '{id}',
        Uri.encodeComponent(rule['exampleId'] as String),
      );
      expect(normalizeUrl(url), url);
    });
  }
  test(
    'unknown-domain tracking and fragment cleanup; repeated queries are kept (spec 0.1.8)',
    () {
      expect(
        normalizeUrl('https://unknown.example/post?id=42&utm_source=a#part'),
        'https://unknown.example/post?id=42',
      );
      // provenance-spec 0.1.8 §5 keeps repeated parameters in order.
      expect(
        normalizeUrl('https://unknown.example/post?id=1&id=2'),
        'https://unknown.example/post?id=1&id=2',
      );
    },
  );
  test('compare Rednote and XHS canonicalization for the same post', () {
    const id = '670f1a2b000000001e028b12';
    const rednote = 'https://www.rednote.com/discovery/item/$id';
    const xhs = 'https://www.xiaohongshu.com/explore/$id';
    final site = SiteRegistry.current.byId('xhs')!;
    expect(site.sourceId(Uri.parse(rednote)), id);
    expect(site.sourceId(Uri.parse(xhs)), id);
    expect(site.canonical(id), xhs);
    // provenance-spec 0.1.8 §5: both domains share the xiaohongshu canonical.
    expect(normalizeUrl(rednote), xhs);
    expect(normalizeUrl(xhs), xhs);
    final rednoteOrigin = buildSiteProvenance(
      platform: 'xhs', capturedBy: 'EasySave/1.10.0',
      sourceId: site.sourceId(Uri.parse(rednote))!, sourceUrl: rednote,
      itemIndex: 1, itemCount: 1,
    );
    final xhsOrigin = buildSiteProvenance(
      platform: 'xhs', capturedBy: 'EasySave/1.10.0',
      sourceId: site.sourceId(Uri.parse(xhs))!, sourceUrl: xhs,
      itemIndex: 1, itemCount: 1,
    );
    expect(sameSavedOrigin(rednoteOrigin, xhsOrigin), isTrue);
  });
}
