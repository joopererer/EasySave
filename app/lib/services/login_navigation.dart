import 'site_registry.dart';

/// Prefer the site's QR tab when offered. Never click account submission or
/// override the site's authentication state; stop observing after ten seconds.
const xhsPreferQrLogin = r'''
(() => {
  if (!/^https:\/\/(www\.)?xiaohongshu\.com\//.test(location.href)) return;
  if (window.__easySaveQrObserver) window.__easySaveQrObserver.disconnect();
  const select = () => {
    const tab = Array.from(document.querySelectorAll('button,[role="tab"],.login-container span,.login-container div'))
      .find(e => e.childElementCount === 0 && e.offsetWidth > 0 &&
        /^(扫码登录|二维码登录)$/.test(e.textContent.trim()));
    if (!tab) return false;
    tab.click();
    return true;
  };
  if (select()) return;
  const observer = new MutationObserver(() => { if (select()) observer.disconnect(); });
  window.__easySaveQrObserver = observer;
  observer.observe(document.documentElement, {childList: true, subtree: true});
  setTimeout(() => observer.disconnect(), 10000);
})();
''';

/// Google does not support OAuth inside embedded WebViews. Do not spoof the UA
/// or pretend a browser session is available to Android's WebView CookieManager.
bool requiresExternalGoogleLogin(Uri uri) =>
    uri.scheme == 'https' &&
    const {
      'accounts.google.com',
      'accounts.google.cn',
    }.contains(uri.host.toLowerCase());

/// Whether a successful login invalidates the error card on screen.
///
/// A card that says "check the Instagram login and retry" describes a state the
/// user just changed: it must disappear as soon as the site reports a session,
/// without another tap on 解析. A card that belongs to a different site is left
/// alone, and an unknown platform (the card was produced by the background
/// engine for a link the input no longer holds) is cleared too.
bool loginClearsErrorCard({
  required String? errorPlatform,
  required String? loginPlatform,
}) =>
    errorPlatform == null ||
    loginPlatform == null ||
    errorPlatform == loginPlatform;

/// Generic fallback when a site has no tailored login instructions.
const googleWebViewLoginMessage =
    'Google 授权不能在此内嵌登录页完成，请返回站点选择其他登录方式。'
    '在外部浏览器登录也不会自动同步到 EasySave。';

String googleLoginMessage(String platform) =>
    SiteRegistry.current.byId(platform)?.auth['externalGoogleMessage']
        as String? ??
    googleWebViewLoginMessage;
