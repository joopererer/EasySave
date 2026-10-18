// v1.6 technical validation only — background parse in a standalone
// FlutterEngine started from a foreground service (no Activity).
//
// This file is intentionally rough and will be replaced by the real
// implementation once the approach is confirmed.

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../services/auth.dart';
import '../services/parse_service.dart';
import '../services/update_service.dart';

const String _channelName = 'easysave/bgtest';

/// Called from the top-level `backgroundMain` in `main.dart` (the entry point
/// the foreground service executes).
void backgroundEntry() {
  WidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(_channelName);
  channel.setMethodCallHandler((call) async {
    if (call.method == 'run') {
      await runBackgroundValidation(channel);
      final urls = (call.arguments as List?)
              ?.map((e) => '$e')
              .toList(growable: false) ??
          const <String>[];
      await bgParseUrls(channel, urls);
    }
    return null;
  });
  channel.invokeMethod<void>('ready');
}

/// Entry point executed by [BgParseService]'s FlutterEngine. Must be a
/// top-level function reachable from `main.dart` (see `backgroundMain` there).
Future<void> runBackgroundValidation(MethodChannel channel) async {
  Future<void> log(String msg) async {
    try {
      await channel.invokeMethod<void>('log', msg);
    } catch (_) {
      // Channel may be gone; nothing else we can do in a headless isolate.
    }
  }

  await log('BG isolate up');
  try {
    await ParserManager.instance.init();
    await log(
      'ParserManager ready: ${ParserManager.instance.activeVersion} '
      '(${ParserManager.instance.activeSourceLabel})',
    );
  } catch (e) {
    await log('ParserManager init FAILED: $e');
  }

  // (A) Cookie store sharing with the main app's WebView.
  try {
    final xhs = await isLoggedIn(PlatformKind.xhs);
    final ig = await isLoggedIn(PlatformKind.instagram);
    final x = await isLoggedIn(PlatformKind.x);
    final header = await cookieHeaderFor([
      'https://www.xiaohongshu.com/',
      'https://www.instagram.com/',
      'https://x.com/',
    ]);
    await log(
      'COOKIES xhs=$xhs ig=$ig x=$x len=${header.length} '
      '${header.isEmpty ? "(EMPTY)" : "(NON-EMPTY)"}',
    );
  } catch (e) {
    await log('COOKIES read FAILED: $e');
  }
}

/// Parse each URL in turn inside the background engine and report the result.
Future<void> bgParseUrls(MethodChannel channel, List<String> urls) async {
  Future<void> log(String msg) async {
    try {
      await channel.invokeMethod<void>('log', msg);
    } catch (_) {}
  }

  for (final raw in urls) {
    final url = raw.trim();
    if (url.isEmpty) continue;
    final sw = Stopwatch()..start();
    try {
      final outcome = await parsePostOutcome(url);
      await log(
        'PARSE OK (${sw.elapsedMilliseconds}ms) ${outcome.data.platform} '
        '"${outcome.data.title ?? ''}" items=${outcome.data.items.length} :: $url',
      );
    } on ParseFailure catch (e) {
      await log(
        'PARSE FAIL[${e.code}] (${sw.elapsedMilliseconds}ms) ${e.message} :: $url',
      );
    } catch (e) {
      await log('PARSE ERR (${sw.elapsedMilliseconds}ms) $e :: $url');
    }
  }
  await log('VALIDATION DONE');
  try {
    await channel.invokeMethod<void>('done');
  } catch (_) {}
}
