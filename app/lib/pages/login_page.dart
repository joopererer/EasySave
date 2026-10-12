// In-app login page: full WebView on the platform site so the user logs in
// with the real web flow. Cookies persist in the shared store.

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../services/auth.dart';

class LoginPage extends StatelessWidget {
  const LoginPage({super.key, required this.platform});

  final PlatformKind platform;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${platformLabel(platform)}登录'),
        actions: [
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
            child: const Text(
              '请在下方页面完成登录，然后点右上角“完成”。登录状态保存在本机，重启 App 依然有效。',
              style: TextStyle(fontSize: 13),
            ),
          ),
          Expanded(
            child: InAppWebView(
              initialUrlRequest: URLRequest(
                url: WebUri(loginEntryUrl(platform)),
              ),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                domStorageEnabled: true,
                mediaPlaybackRequiresUserGesture: false,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
