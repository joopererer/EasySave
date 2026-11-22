import 'package:easysave/services/auth.dart';
import 'package:easysave/services/links.dart';
import 'package:easysave/services/parse_service.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const postId = '670f1a2b000000001e028b12';
  const rednotePost =
      'https://www.rednote.com/discovery/item/$postId?xsec_token=token&xsec_source=share';
  const mainlandPost =
      'https://www.xiaohongshu.com/discovery/item/$postId?xsec_token=token&xsec_source=share';

  setUp(() {
    SiteRegistry.useBuiltin();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(SiteRegistry.useBuiltin);

  group('XhsDomainCoordinator and switch bounds', () {
    test('allows at most 1 alternate domain switch per parse session', () async {
      await saveXhsDomainStatus('xiaohongshu.com', SessionStatus.valid);
      await saveXhsDomainStatus('rednote.com', SessionStatus.invalid);

      final coordinator = XhsDomainCoordinator(maxSwitches: 1);
      expect(coordinator.canSwitch, isTrue);
      expect(coordinator.switchCount, 0);

      // First call: switches from rednote to xiaohongshu
      final firstChoice = await selectXhsPostUrl(
        rednotePost,
        postId,
        coordinator: coordinator,
      );
      expect(Uri.parse(firstChoice).host, 'www.xiaohongshu.com');
      expect(coordinator.switchCount, 1);
      expect(coordinator.canSwitch, isFalse);
      expect(coordinator.switchReasons.length, 1);
      expect(coordinator.switchReasons.first, contains('reason=alias_valid'));

      // Second call (e.g. redirected again): must NOT switch back or loop
      final secondChoice = await selectXhsPostUrl(
        rednotePost,
        postId,
        coordinator: coordinator,
      );
      expect(Uri.parse(secondChoice).host, 'www.rednote.com',
          reason: 'Switch limit reached, remains on current origin');
      expect(coordinator.switchCount, 1);
    });

    test('valid original domain does not consume switch allowance', () async {
      await saveXhsDomainStatus('xiaohongshu.com', SessionStatus.valid);
      await saveXhsDomainStatus('rednote.com', SessionStatus.valid);

      final coordinator = XhsDomainCoordinator(maxSwitches: 1);
      final choice = await selectXhsPostUrl(
        mainlandPost,
        postId,
        coordinator: coordinator,
      );
      expect(Uri.parse(choice).host, 'www.xiaohongshu.com');
      expect(coordinator.switchCount, 0);
      expect(coordinator.canSwitch, isTrue);
    });

    test('rednote alternate domain for overseas users works normally for 1 switch', () async {
      await saveXhsDomainStatus('xiaohongshu.com', SessionStatus.invalid);
      await saveXhsDomainStatus('rednote.com', SessionStatus.valid);

      final coordinator = XhsDomainCoordinator(maxSwitches: 1);
      final choice = await selectXhsPostUrl(
        mainlandPost,
        postId,
        coordinator: coordinator,
      );
      expect(Uri.parse(choice).host, 'www.rednote.com');
      expect(coordinator.switchCount, 1);
    });
  });

  group('Unauthenticated redirect detection', () {
    test('recognizes bare /explore and /login as unauthenticated redirects', () {
      expect(
        isXhsUnauthenticatedRedirect(Uri.parse('https://www.xiaohongshu.com/explore')),
        isTrue,
      );
      expect(
        isXhsUnauthenticatedRedirect(Uri.parse('https://www.xiaohongshu.com/explore/')),
        isTrue,
      );
      expect(
        isXhsUnauthenticatedRedirect(Uri.parse('https://www.rednote.com/explore')),
        isTrue,
      );
      expect(
        isXhsUnauthenticatedRedirect(Uri.parse('https://www.xiaohongshu.com/login')),
        isTrue,
      );
      expect(
        isXhsUnauthenticatedRedirect(Uri.parse('https://www.rednote.com/login?redirect=...')),
        isTrue,
      );
      expect(
        isXhsUnauthenticatedRedirect(Uri.parse('https://www.xiaohongshu.com/')),
        isTrue,
      );
    });

    test('does not misclassify valid post links as unauthenticated redirects', () {
      expect(
        isXhsUnauthenticatedRedirect(Uri.parse('https://www.xiaohongshu.com/explore/$postId')),
        isFalse,
      );
      expect(
        isXhsUnauthenticatedRedirect(Uri.parse('https://www.rednote.com/discovery/item/$postId')),
        isFalse,
      );
      expect(
        isXhsUnauthenticatedRedirect(Uri.parse('https://www.xiaohongshu.com/user/profile/user123/$postId')),
        isFalse,
      );
    });

    test('chooseFinalParseUrl bypasses switching on unauthenticated redirect pages', () async {
      final site = SiteRegistry.current.byId('xhs')!;
      final coordinator = XhsDomainCoordinator(maxSwitches: 1);
      const exploreUrl = 'https://www.rednote.com/explore';

      final selected = await chooseFinalParseUrl(
        exploreUrl,
        site,
        coordinator: coordinator,
      );
      expect(selected, exploreUrl);
      expect(coordinator.switchCount, 0,
          reason: 'Must not attempt domain switching on landing pages');
    });
  });
}

