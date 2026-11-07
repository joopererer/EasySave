import 'package:easysave/core/error_copy.dart';
import 'package:easysave/core/models.dart';
import 'package:easysave/services/parse_service.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:flutter_test/flutter_test.dart';

/// A passed-in link without `xsec_token` is rejected by xiaohongshu with its own
/// 404 route even when the post exists. The App must not blame the post then.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(SiteRegistry.useBuiltin);
  tearDown(SiteRegistry.useBuiltin);

  SiteDefinition site() => SiteRegistry.current.byId('xhs')!;

  // The site redirects an unavailable page to its own /404 route, which drops
  // the original query string; the token rule has to read the requested URL.
  const notFoundPage = 'https://www.rednote.com/404?redirectPath=%2Fexplore%2Fx';
  const postWithoutToken =
      'https://www.rednote.com/explore/6a1bcbdf0000000038020654';
  const postWithToken =
      'https://www.xiaohongshu.com/explore/6a1bcbdf0000000038020654'
      '?xsec_token=synthetic_token&xsec_source=pc_share';
  const postWithEmptyToken =
      'https://www.xiaohongshu.com/explore/6a1bcbdf0000000038020654'
      '?xsec_token=&xsec_source=pc_share';

  test('a 404 for a link without xsec_token reports the missing token', () {
    final failure = terminalPageFailure(
      site(),
      Uri.parse(notFoundPage),
      requestedUri: Uri.parse(postWithoutToken),
    );
    expect(failure, isNotNull);
    expect(failure!.code, ParseErrorCode.tokenRequired);
    expect(failure.message, contains('链接缺少访问令牌'));
    expect(failure.message, contains('分享'));
    expect(
      displayErrorMessage(failure.code, failure.message),
      contains('链接缺少访问令牌'),
    );
  });

  test('a 404 for a link with xsec_token keeps the post-not-found copy', () {
    final failure = terminalPageFailure(
      site(),
      Uri.parse(notFoundPage),
      requestedUri: Uri.parse(postWithToken),
    );
    expect(failure!.code, ParseErrorCode.postNotFound);
    expect(failure.message, '帖子不存在，或链接已失效');
  });

  test('an empty xsec_token counts as a missing token', () {
    final failure = terminalPageFailure(
      site(),
      Uri.parse(notFoundPage),
      requestedUri: Uri.parse(postWithEmptyToken),
    );
    expect(failure!.code, ParseErrorCode.tokenRequired);
  });

  test('login and captcha pages are unaffected by the token rule', () {
    expect(
      terminalPageFailure(
        site(),
        Uri.parse('https://www.rednote.com/login'),
        requestedUri: Uri.parse(postWithoutToken),
      )!.code,
      ParseErrorCode.loginRequired,
    );
    expect(
      terminalPageFailure(
        site(),
        Uri.parse('https://www.rednote.com/website-login/captcha'),
        requestedUri: Uri.parse(postWithoutToken),
      )!.code,
      ParseErrorCode.loginRequired,
    );
  });

  test('a page that is not terminal returns no failure', () {
    expect(
      terminalPageFailure(
        site(),
        Uri.parse(postWithoutToken),
        requestedUri: Uri.parse(postWithoutToken),
      ),
      isNull,
    );
  });
}
