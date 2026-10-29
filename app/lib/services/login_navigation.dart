import 'site_registry.dart';

/// Google does not support OAuth inside embedded WebViews. Do not spoof the UA
/// or pretend a browser session is available to Android's WebView CookieManager.
bool requiresExternalGoogleLogin(Uri uri) =>
    uri.scheme == 'https' &&
    const {
      'accounts.google.com',
      'accounts.google.cn',
    }.contains(uri.host.toLowerCase());

/// Generic fallback when a site has no tailored login instructions.
const googleWebViewLoginMessage =
    'Google 授权不能在此内嵌登录页完成，请返回站点选择其他登录方式。'
    '在外部浏览器登录也不会自动同步到 EasySave。';

String googleLoginMessage(String platform) =>
    SiteRegistry.current.byId(platform)?.auth['externalGoogleMessage']
        as String? ??
    googleWebViewLoginMessage;
