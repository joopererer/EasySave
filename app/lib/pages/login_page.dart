// In-app login page: full WebView on the platform site so the user logs in
// with the real web flow. Cookies persist in the shared store.
//
// Sign-in state is read from the page itself (`__INITIAL_STATE__.user`), the
// same way XHS_Downloader_Android does it: it is authoritative, instant, and
// avoids extra network round-trips that used to make "完成" feel broken.
//
// XHS's login page also probes 127.0.0.1 (to detect its desktop client) and
// redirects there after login. Nothing listens on that port inside the app,
// so loopback navigations are cancelled and only a main-frame hand-off during
// an unfinished login is treated as a hint.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../services/auth.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.platform});

  final PlatformKind platform;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  InAppWebViewController? _controller;
  double _progress = 0;
  bool _verifying = false;
  bool _handlingCallback = false;
  bool _callbackNoticeShown = false;

  /// Set when the main document failed to load; shows the retry card.
  String? _loadError;
  bool _dnsRetried = false;

  /// First successful paint of the page, so the placeholder disappears even if
  /// the progress bar never reports 100%.
  bool _pageReady = false;

  Timer? _pollTimer;

  bool get _isXhs => widget.platform == PlatformKind.xhs;

  String get _entryUrl => loginEntryUrl(widget.platform);

  /// XHS keeps `__INITIAL_STATE__` in sync with the actual session, so we can
  /// watch it while the user types/logs in: no reload needed, and the "完成"
  /// button becomes an instant confirmation when a session is already there.
  void _startPolling() {
    if (!_isXhs) return;
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) async {
      final controller = _controller;
      if (controller == null || _verifying) return;
      final account = await readXhsAccount(controller);
      if (account == null || !account.loggedIn) return;
      await XhsAccountCache.save(account);
      if (!mounted) return;
      _pollTimer?.cancel();
      LoginExpiredBus.clear(widget.platform);
      Navigator.of(context).pop(true);
    });
  }

  @override
  void initState() {
    super.initState();
    _startPolling();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  /// Re-check the session and report the result to the caller.
  ///
  /// Returns true when the session was confirmed and the page popped.
  Future<bool> _handleComplete() async {
    if (_verifying) return false;
    // Give Android CookieManager a brief moment to persist cookies.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    if (!mounted) return false;

    setState(() => _verifying = true);
    final ok = await checkLogin(
      widget.platform,
      webViewController: _controller,
    );
    if (!mounted) return ok;
    setState(() => _verifying = false);

    if (ok) {
      LoginExpiredBus.clear(widget.platform);
      Navigator.of(context).pop(true);
      return true;
    }

    final confirmExit = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('未检测到登录状态'),
        content: Text(
          _isXhs
              ? '页面还没有显示登录成功。\n\n请输入手机号获取验证码完成登录（可切换密码登录），登录成功后会自动返回。'
              : '尚未检测到登录信息，确定要退出吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('仍要退出'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('继续登录'),
          ),
        ],
      ),
    );
    if (confirmExit != true || !mounted) return false;
    Navigator.of(context).pop(false);
    return false;
  }

  /// Called when the page tries to navigate to a loopback callback.
  ///
  /// That redirect is a post-login hand-off to the desktop client. There is no
  /// listener here, so we drop it and check the page state: logged in means we
  /// close automatically, otherwise the user stays right where they were
  /// (reloading would trigger the very same redirect again).
  Future<void> _onLocalCallback() async {
    if (_handlingCallback) return;
    _handlingCallback = true;
    try {
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (!mounted) return;
      final ok = await checkLogin(
        widget.platform,
        webViewController: _controller,
      );
      if (!mounted) return;
      if (ok) {
        LoginExpiredBus.clear(widget.platform);
        Navigator.of(context).pop(true);
        return;
      }
      if (_callbackNoticeShown) return;
      _callbackNoticeShown = true;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('页面跳转到本地回调（小红书电脑版专用），已自动忽略'),
          duration: Duration(seconds: 3),
        ),
      );
    } finally {
      _handlingCallback = false;
    }
  }

  void _reload() {
    setState(() {
      _loadError = null;
      _dnsRetried = false;
      _pageReady = false;
    });
    final controller = _controller;
    if (controller == null) return;
    controller.loadUrl(urlRequest: URLRequest(url: WebUri(_entryUrl)));
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bannerBg = isDark ? const Color(0xFF26201C) : Colors.blue.shade50;
    final bannerText = isDark ? const Color(0xFFF5ECE6) : Colors.blue.shade900;

    return Scaffold(
      appBar: AppBar(
        title: Text('${platformLabel(widget.platform)}登录'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white),
            tooltip: '刷新',
            onPressed: _reload,
          ),
          TextButton(
            onPressed: _verifying ? null : _handleComplete,
            child: _verifying
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text('完成', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            color: bannerBg,
            child: Text(
              _isXhs
                  ? '页面加载后输入手机号获取验证码登录（也可切换密码登录），登录成功会自动返回。登录状态保存在本机，重启 App 依然有效。'
                  : '请在此页面完成登录，成功后点右上角“完成”。登录状态保存在本机，重启 App 依然有效。',
              style: TextStyle(fontSize: 12, color: bannerText, height: 1.5),
            ),
          ),
          if (_progress > 0 && _progress < 1)
            LinearProgressIndicator(value: _progress, minHeight: 2),
          Expanded(
            child: Stack(
              children: [
                InAppWebView(
                  initialUrlRequest: URLRequest(url: WebUri(_entryUrl)),
                  initialSettings: InAppWebViewSettings(
                    javaScriptEnabled: true,
                    domStorageEnabled: true,
                    databaseEnabled: true,
                    thirdPartyCookiesEnabled: true,
                    sharedCookiesEnabled: true,
                    cacheEnabled: true,
                    mixedContentMode:
                        MixedContentMode.MIXED_CONTENT_COMPATIBILITY_MODE,
                    mediaPlaybackRequiresUserGesture: false,
                    userAgent: loginUserAgent(widget.platform),
                  ),
                  onWebViewCreated: (controller) => _controller = controller,
                  onProgressChanged: (controller, progress) {
                    if (!mounted) return;
                    setState(() => _progress = progress / 100);
                  },
                  shouldOverrideUrlLoading: (controller, navigationAction) async {
                    final uri = navigationAction.request.url;
                    if (uri == null) return NavigationActionPolicy.ALLOW;
                    // XHS hands the finished login off to a desktop-client
                    // listener on localhost. Only main-frame navigations are
                    // meaningful here: probe requests to loopback must be
                    // dropped silently or the page would ping-pong forever.
                    if (isLoopbackHost(uri.host)) {
                      if (navigationAction.isForMainFrame == true) {
                        _onLocalCallback();
                      }
                      return NavigationActionPolicy.CANCEL;
                    }
                    // The app has no native bridge for platform schemes.
                    if (uri.scheme != 'http' && uri.scheme != 'https') {
                      return NavigationActionPolicy.CANCEL;
                    }
                    if (uri.scheme == 'http') {
                      // Upgrade cleartext, but only for the main document:
                      // rewriting subframe URLs can bounce the page forever.
                      if (navigationAction.isForMainFrame == true) {
                        final httpsUri = uri.replace(scheme: 'https');
                        controller.loadUrl(
                          urlRequest: URLRequest(url: WebUri.uri(httpsUri)),
                        );
                      }
                      return NavigationActionPolicy.CANCEL;
                    }
                    return NavigationActionPolicy.ALLOW;
                  },
                  onReceivedError: (controller, request, error) {
                    // Subresource failures (XHS probes 127.0.0.1 to detect
                    // its desktop client) must never trigger a page load,
                    // otherwise the WebView reloads forever.
                    if (request.isForMainFrame != true) return;
                    final uri = request.url;
                    if (isLoopbackHost(uri.host)) {
                      _onLocalCallback();
                      return;
                    }
                    final isDnsError = error.description
                        .toUpperCase()
                        .contains('NAME_NOT_RESOLVED');
                    if (isDnsError && !_dnsRetried) {
                      // A single silent retry: transient DNS hiccups are
                      // common right after switching networks.
                      _dnsRetried = true;
                      Future<void>.delayed(const Duration(seconds: 2), () {
                        if (mounted) _reload();
                      });
                      return;
                    }
                    if (!mounted) return;
                    setState(() => _loadError = error.description);
                  },
                  onLoadStop: (controller, url) {
                    // A real page finished loading: allow one more loopback
                    // notice if the hand-off happens again later.
                    _callbackNoticeShown = false;
                    if (mounted &&
                        (_loadError != null || !_pageReady)) {
                      setState(() {
                        _loadError = null;
                        _pageReady = true;
                      });
                    }
                  },
                ),
                // Cover the blank WebView while the first paint happens, so
                // the page never flashes black.
                if (!_pageReady && _loadError == null)
                  Positioned.fill(
                    child: ColoredBox(
                      color: Theme.of(context).scaffoldBackgroundColor,
                      child: const Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(strokeWidth: 2),
                            SizedBox(height: 12),
                            Text(
                              '正在加载登录页面…',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.black54,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (_loadError != null)
                  Positioned.fill(child: _buildErrorCard()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorCard() {
    final detail = _loadError ?? '';
    final isDns = detail.toUpperCase().contains('NAME_NOT_RESOLVED');
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.wifi_off, size: 40, color: Colors.grey),
              const SizedBox(height: 16),
              Text(
                isDns ? '无法解析小红书域名' : '登录页面加载失败',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                isDns
                    ? '当前网络无法解析 xiaohongshu.com（常见于部分网络环境或代理未开启）。\n请切换网络/开启代理后重试。'
                    : detail,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 20),
              FilledButton(onPressed: _reload, child: const Text('重试')),
            ],
          ),
        ),
      ),
    );
  }
}
