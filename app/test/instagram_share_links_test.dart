import 'package:easysave/services/links.dart';
import 'package:easysave/services/parse_service.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(SiteRegistry.useBuiltin);
  for (final (route, id) in [('reel', 'DfTxDNBJOef'), ('p', 'DfODzLIEoca')]) {
    for (final query in ['dlrf=123456', 'vrfl=1', 'dlrf=123456&vrfl=1']) {
      test(
        'Instagram /$route/ share params $query preserve post identity',
        () async {
          final url = 'https://www.instagram.com/$route/$id/?$query';
          expect(extractLink('shared $url'), url);
          expect(isSupportedLink(url), isTrue);
          final site = SiteRegistry.current.match(url)!;
          expect(site.id, 'instagram');
          expect(site.sourceId(Uri.parse(url)), id);
          expect(
            SiteRegistry.current.canonicalUrl(url),
            'https://www.instagram.com/p/$id/',
          );
          await resolveAndEnterParse(
            url,
            site,
            (load, canonical) async {
              expect(load, url);
              expect(canonical, 'https://www.instagram.com/p/$id/');
            },
            readRedirect: (_) async => throw StateError('not a short link'),
          );
        },
      );
    }
  }
}
