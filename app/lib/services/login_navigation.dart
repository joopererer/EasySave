/// Google does not support OAuth inside embedded WebViews. Do not spoof the UA
/// or pretend a browser session is available to Android's WebView CookieManager.
bool requiresExternalGoogleLogin(Uri uri) =>
    uri.scheme == 'https' &&
    const {'accounts.google.com', 'accounts.google.cn'}.contains(uri.host.toLowerCase());

const googleWebViewLoginMessage =
    'Google 授权不能在此内嵌登录页完成。请返回 TikTok，选择“手机号 / 邮箱 / 用户名”登录。'
    '如果使用 Gmail 地址，请输入 TikTok 账号密码，不是 Google 密码。'
    '在外部浏览器登录也不会自动同步到 EasySave。';
