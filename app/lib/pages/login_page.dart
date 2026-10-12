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

  @override
  Widget build(BuildContext context) {
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
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('完成', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            color: Colors.blue.shade50,
            child: Text(
              widget.platform == PlatformKind.xhs
                  ? '点右上角“登录”后用小红书 App 扫码，完成后点右上角“完成”。登录状态保存在本机，重启 App 依然有效。'
                  : '请在下方页面完成登录，然后点右上角“完成”。登录状态保存在本机，重启 App 依然有效。',
              style: const TextStyle(fontSize: 13),
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
