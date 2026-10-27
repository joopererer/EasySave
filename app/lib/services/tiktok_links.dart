import 'package:provenance_dart/provenance_dart.dart';

/// Desktop detail includes bitrate variants absent from the mobile reflow page.
/// Used only by the parser, never to disguise the Google login WebView.
const tiktokParserUserAgent =
    'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36';

const tiktokStateReadyScript = r'''
(() => {
  try {
    const node = document.getElementById('__UNIVERSAL_DATA_FOR_REHYDRATION__');
    const root = window.__UNIVERSAL_DATA_FOR_REHYDRATION__ ||
      (node && JSON.parse(node.textContent));
    const scope = root && root.__DEFAULT_SCOPE__;
    return !!(scope && ['webapp.video-detail', 'webapp.reflow.video.detail'].some(key => {
      const detail = scope[key];
      return detail && ((detail.itemInfo && detail.itemInfo.itemStruct && detail.itemInfo.itemStruct.id) ||
        (detail.statusCode != null && Number(detail.statusCode) !== 0));
    }));
  } catch (_) { return false; }
})()
''';

Future<void> waitForTiktokState(Future<bool> Function() isReady, {
  Duration timeout = const Duration(seconds: 6),
  Duration interval = const Duration(milliseconds: 250),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    try {
      if (await isReady()) {
        return;
      }
    } catch (_) {
      // A canonical navigation can briefly replace the JavaScript context.
    }
    await Future<void>.delayed(interval);
  }
}

bool isTiktokHost(String host) => const {
  'tiktok.com', 'www.tiktok.com', 'm.tiktok.com',
  'vm.tiktok.com', 'vt.tiktok.com',
}.contains(host.toLowerCase());

bool isTiktokLink(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || !['http', 'https'].contains(uri.scheme) ||
      !isTiktokHost(uri.host)) return false;
  if (uri.host == 'vm.tiktok.com' || uri.host == 'vt.tiktok.com') {
    return RegExp(r'^/[^/]+/?$').hasMatch(uri.path);
  }
  return extractTiktokPostId(url) != null;
}

/// A short URL must be expanded by WebView before calling this helper.
String? canonicalTiktokUrl(String url) {
  if (!isTiktokLink(url) || extractTiktokPostId(url) == null) return null;
  return normalizeUrl(url);
}
