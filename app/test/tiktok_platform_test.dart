import 'package:easysave/metadata/url_normalizer.dart';
import 'package:easysave/services/auth.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/widgets/shared.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('TikTok login routing recognizes short and canonical hosts only', () {
    for (final host in ['www.tiktok.com', 'vm.tiktok.com', 'vt.tiktok.com']) {
      expect(platformFromUrl('https://$host/path'), PlatformKind.tiktok);
    }
    expect(platformFromUrl('https://tiktok.com.evil.example/path'), isNull);
    expect(platformFromKey('tiktok'), PlatformKind.tiktok);
    expect(platformLabel(PlatformKind.tiktok), 'TikTok');
    expect(loginEntryUrl(PlatformKind.tiktok), 'https://www.tiktok.com/login');
  });

  test('TikTok metadata maps platform and only writes numeric author IDs', () {
    expect(toSpecPlatform('tiktok'), 'tiktok');
    expect(toAppPlatform('tiktok'), 'tiktok');
    expect(platformDisplayName('tiktok'), 'TikTok');
    for (final author in ['123456789', 'username', '']) {
      final batch = DownloadBatch(batchId: 'b', album: 'a',
        postUrl: 'https://www.tiktok.com/@/video/123456', platform: 'tiktok',
        postId: '123456', authorId: author, jobs: []);
      final provenance = provenanceForBatchItem(batch, itemIndex: 1);
      expect(provenance.authorId, author == '123456789' ? author : null);
      expect(provenance.platform, 'tiktok');
    }
  });

  testWidgets('TikTok tag is visibly distinct from Instagram', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: PlatformTag(platform: 'tiktok'))));
    expect(find.text('TikTok'), findsOneWidget);
    expect(find.text('Instagram'), findsNothing);
  });
}
