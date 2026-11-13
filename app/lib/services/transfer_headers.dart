// One header set for every transfer of the same media URL.
//
// The preflight and the session transfer run on `dart:io`, the background
// download on the plugin's native OkHttp stack. They differ in User-Agent and
// in transport encoding unless both are told explicitly, and a CDN that sees a
// different client for the HEAD than for the GET can answer the GET with a
// connection reset. Everything a transfer sends is decided here, once.

/// Browser User-Agent used for media transfers unless the site declares one.
/// The XHS CDN rejects (or resets) unfamiliar clients on some edges even when
/// the Referer is correct.
const String kTransferUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36';

/// `identity` keeps the bytes exactly as stored, so a ranged probe and a full
/// transfer agree on sizes and a resume never sees a different encoding.
const String kTransferAcceptEncoding = 'identity';

/// [declared] (validated site/resource headers) plus the two headers every
/// transfer carries. A declared value always wins.
Map<String, String> unifiedTransferHeaders(Map<String, String> declared) {
  bool has(String name) =>
      declared.keys.any((key) => key.toLowerCase() == name.toLowerCase());
  return {
    if (!has('user-agent')) 'User-Agent': kTransferUserAgent,
    if (!has('accept-encoding')) 'Accept-Encoding': kTransferAcceptEncoding,
    ...declared,
  };
}
