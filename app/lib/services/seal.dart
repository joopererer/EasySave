// Seal handoff for YouTube links (roadmap v1.2). EasySave never parses or
// downloads YouTube: the URL is handed to Seal (com.junkfood.seal) via an
// explicit ACTION_SEND intent, or the user gets install guidance.

import 'package:flutter/services.dart';

class SealMissing implements Exception {
  const SealMissing();
}

/// Package name of Seal, the YouTube downloader we hand off to.
const String sealPackage = 'com.junkfood.seal';

/// Seal's GitHub releases, used in the install guidance.
const String sealReleasesUrl = 'https://github.com/JunkFood02/Seal/releases';

const _channel = MethodChannel('easysave/seal');

/// True when Seal is installed (PackageManager lookup through MainActivity).
Future<bool> isSealInstalled() async {
  try {
    return await _channel.invokeMethod<bool>('isInstalled') ?? false;
  } catch (_) {
    return false;
  }
}

/// Send the URL to Seal with an explicit package intent. Throws [SealMissing]
/// when Seal is not installed so the caller shows install guidance instead.
Future<void> sendToSeal(String url) async {
  try {
    final sent = await _channel.invokeMethod<bool>('send', {'url': url});
    if (sent != true) throw const SealMissing();
  } on SealMissing {
    rethrow;
  } catch (_) {
    throw const SealMissing();
  }
}
