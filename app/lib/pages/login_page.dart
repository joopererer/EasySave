// In-app login page: full WebView on the platform site so the user logs in
// with the real web flow. Cookies persist in the shared store.

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

  Future<void> _handleComplete() async {
    final ok = await isLoggedIn(widget.platform);
    if (!mounted) return;

    if (!ok) {
      final confirmExit = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('未检测到登录状态'),
          content: Text(
            widget.platform == PlatformKind.xhs
                ? '尚未检测到小红书登录信息。\n\n若尚未登录，请点击下方页面右下角“我”或任意笔记进入登录页面；\n若您刚刚已完成登录，请点击右上角刷新图标，或稍等数秒后再点“完成”。'
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
      if (confirmExit != true || !mounted) return;
    }

    Navigator.of(context).pop(ok);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bannerBg = isDark ? const Color(0xFF1E293B) : Colors.blue.shade50;
    final bannerText = isDark ? const Color(0xFF93C5FD) : Colors.blue.shade900;

    return Scaffold(
      appBar: AppBar(
        title: Text('${platformLabel(widget.platform)}登录'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white),
            tooltip: '刷新',
            onPressed: () => _controller?.reload(),
          ),
          TextButton(
            onPressed: _handleComplete,
            child: const Text('完成', style: TextStyle(color: Colors.white)),
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
              widget.platform == PlatformKind.xhs
                  ? '若显示手机版页面，可点击右下角“我”或任意笔记进入登录；若显示桌面版，可切换“验证码/密码登录”。登录成功后点右上角“完成”。登录状态保存在本机，重启 App 依然有效。'
                  : '请在下方页面完成登录，然后点右上角“完成”。登录状态保存在本机，重启 App 依然有效。',
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                color: bannerText,
              ),
            ),
          ),
          if (_progress < 1)
            LinearProgressIndicator(value: _progress == 0 ? null : _progress),
          Expanded(
            child: InAppWebView(
              initialUrlRequest: URLRequest(
                url: WebUri(loginEntryUrl(widget.platform)),
              ),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                domStorageEnabled: true,
                databaseEnabled: true,
                thirdPartyCookiesEnabled: true,
                sharedCookiesEnabled: true,
                cacheEnabled: true,
                mediaPlaybackRequiresUserGesture: false,
                userAgent: loginUserAgent(widget.platform),
              ),
              onWebViewCreated: (controller) => _controller = controller,
              onProgressChanged: (controller, progress) {
                if (!mounted) return;
                setState(() => _progress = progress / 100);
              },
            ),
          ),
        ],
      ),
    );
  }
}
