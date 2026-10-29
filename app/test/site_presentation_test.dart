import 'package:easysave/services/auth.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:easysave/widgets/shared.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(SiteRegistry.useBuiltin);
  test(
    'names prefer current manifest including disabled sites, then saved name, then id',
    () {
      SiteRegistry.activate([
        {
          'id': 'retired',
          'platform': 'retired',
          'displayName': '新名称',
          'enabled': false,
        },
      ]);
      expect(platformLabel('retired', savedDisplayName: '旧名称'), '新名称');
      SiteRegistry.activate([]);
      expect(platformLabel('retired', savedDisplayName: '旧名称'), '旧名称');
      expect(platformLabel('retired', savedDisplayName: ' '), 'retired');
      expect(platformLabel('retired'), 'retired');
    },
  );
  test(
    'login host recognition uses manifest domains with safe URL boundaries',
    () {
      expect(platformFromUrl('https://www.xiaohongshu.com/'), 'xhs');
      expect(platformFromUrl('https://twitter.com/'), 'x');
      for (final url in [
        'https://eviltwitter.com/',
        'https://x.com.evil.test/',
        'https://x.com@evil.test/',
        'file://x.com/',
      ]) {
        expect(platformFromUrl(url), isNull);
      }
    },
  );
  testWidgets(
    'new site reads manifest name, color and a locally registered asset key',
    (tester) async {
      SiteRegistry.activate([
        {
          'id': 'new_site',
          'platform': 'new_site',
          'displayName': '新站点',
          'enabled': true,
          'tagColor': '#123456',
          'icon': {'assetKey': 'instagram'},
        },
      ]);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: PlatformTag(platform: 'new_site')),
        ),
      );
      expect(find.text('新站点'), findsOneWidget);
      expect(find.byIcon(Icons.photo_camera), findsOneWidget);
      final container = tester
          .widgetList<Container>(
            find.descendant(
              of: find.byType(PlatformTag),
              matching: find.byType(Container),
            ),
          )
          .first;
      expect(
        (container.decoration as BoxDecoration).color,
        const Color(0xFF123456),
      );
      SiteRegistry.activate([
        {
          'id': 'new_site',
          'platform': 'new_site',
          'displayName': '新站点',
          'enabled': true,
          'icon': {'assetKey': 'unknown'},
        },
      ]);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: PlatformTag(platform: 'new_site')),
        ),
      );
      expect(find.byIcon(Icons.public), findsOneWidget);
    },
  );
}
