import 'dart:convert';
import 'dart:io';

import 'package:easysave/services/login_navigation.dart';
import 'package:easysave/services/preview_video.dart';
import 'package:easysave/services/signed_parser_manifest.dart';
import 'package:easysave/services/auth.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:easysave/widgets/shared.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(SiteRegistry.useBuiltin);
  test(
    'site login and playback messages preserve builtins and follow active manifest',
    () {
      SiteRegistry.useBuiltin();
      expect(
        googleLoginMessage('tiktok'),
        'Google 授权不能在此内嵌登录页完成。请返回 TikTok，选择“手机号 / 邮箱 / 用户名”登录。'
        '如果使用 Gmail 地址，请输入 TikTok 账号密码，不是 Google 密码。'
        '在外部浏览器登录也不会自动同步到 EasySave。',
      );
      expect(previewPlaybackError('tiktok'), 'TikTok 在线预览可能受平台限制，请下载后观看');
      SiteRegistry.activate([
        {
          'id': 'future_site',
          'platform': 'future_site',
          'auth': {'externalGoogleMessage': 'Use this site login'},
          'previewErrorMessage': 'Save this media first',
        },
      ]);
      expect(googleLoginMessage('future_site'), 'Use this site login');
      expect(previewPlaybackError('future_site'), 'Save this media first');
      expect(googleLoginMessage('retired'), googleWebViewLoginMessage);
      expect(previewPlaybackError('retired'), '暂时无法播放，请重试或下载后观看');
    },
  );
  test('site message schema accepts strings and rejects invalid values', () {
    final schema =
        jsonDecode(
              File(
                'assets/parser/sites-manifest.schema.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final payload =
        jsonDecode(
              File('assets/parser/builtin-manifest.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
    final rule = (schema[r'$defs'] as Map)['payload'] as Map;
    validateManifestSchema(payload, rule, schema);
    final site = (payload['sites'] as List).first as Map;
    for (final invalid in <dynamic>[
      true,
      1,
      '',
      List.filled(2049, 'a').join(),
    ]) {
      site['previewErrorMessage'] = invalid;
      expect(
        () => validateManifestSchema(payload, rule, schema),
        throwsFormatException,
      );
      site.remove('previewErrorMessage');
      (site['auth'] as Map)['externalGoogleMessage'] = invalid;
      expect(
        () => validateManifestSchema(payload, rule, schema),
        throwsFormatException,
      );
      (site['auth'] as Map).remove('externalGoogleMessage');
    }
  });
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
