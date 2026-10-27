import 'package:easysave/services/auth.dart';
import 'package:easysave/services/login_navigation.dart';
import 'package:easysave/services/tiktok_links.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('waits through navigation and hydration before parsing', () async {
    var calls = 0;
    await waitForTiktokState(() async {
      calls++;
      if (calls == 1) throw StateError('navigation replaced JS context');
      return calls >= 3;
    }, interval: Duration.zero, timeout: const Duration(seconds: 1));
    expect(calls, 3);
  });
  test('empty TikTok state has a bounded wait', () async {
    await waitForTiktokState(() async => false,
      interval: Duration.zero, timeout: const Duration(milliseconds: 5));
  });
  test('Google account selection is recognized without matching unrelated hosts', () {
    expect(requiresExternalGoogleLogin(Uri.parse('https://accounts.google.com/o/oauth2/v2/auth')), true);
    expect(requiresExternalGoogleLogin(Uri.parse('https://accounts.google.com/AccountChooser')), true);
    expect(requiresExternalGoogleLogin(Uri.parse('https://accounts.google.com.evil.test/')), false);
    expect(requiresExternalGoogleLogin(Uri.parse('https://www.tiktok.com/login')), false);
  });
  test('desktop parser UA is isolated from TikTok login', () {
    expect(tiktokParserUserAgent, contains('X11; Linux x86_64'));
    expect(loginUserAgent(PlatformKind.tiktok), isNull);
  });
  test('reported short-link destinations canonicalize video and photo correctly', () {
    expect(canonicalTiktokUrl('https://www.tiktok.com/@user576329753/video/7698442078988061984?_r=1'),
      'https://www.tiktok.com/@/video/7698442078988061984');
    expect(canonicalTiktokUrl('https://www.tiktok.com/@xo901970f6s/photo/7688352288666045718?_r=1'),
      'https://www.tiktok.com/@/video/7688352288666045718');
  });
}
