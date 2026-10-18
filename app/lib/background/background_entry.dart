// v1.6 background task host. Runs in the FlutterEngine started by HostService
// (no Activity). Step ①: engine ready + submit → parse → idle. The download
// chain is added in step ②.

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../services/parse_service.dart';
import '../services/update_service.dart';

const String _channelName = 'easysave/bgtask';

/// Entry point executed by [HostService]'s FlutterEngine (see `backgroundMain`
/// in `main.dart`).
void backgroundEntry() {
  WidgetsFlutterBinding.ensureInitialized();
  final channel = MethodChannel(_channelName);
  channel.setMethodCallHandler((call) async {
    switch (call.method) {
      case 'submit':
        await _handleSubmit(channel, (call.arguments as Map?) ?? const {});
        break;
    }
    return null;
  });
  channel.invokeMethod('ready');
}

Future<void> _log(MethodChannel channel, String msg) async {
  try {
    await channel.invokeMethod<void>('log', msg);
  } catch (_) {
    // Channel may be gone; nothing else we can do in a headless isolate.
  }
}

Future<void> _handleSubmit(MethodChannel channel, Map<dynamic, dynamic> args) async {
  final mode = args['mode']?.toString() ?? 'all';
  final urls = (args['urls'] as List?)?.map((e) => '$e').toList() ?? const <String>[];
  await _log(channel, 'submit: mode=$mode urls=${urls.length} source=${args['source']}');
  try {
    await channel.invokeMethod<void>('keepAlive');
  } catch (_) {}

  try {
    await ParserManager.instance.init();
    await _log(
      channel,
      'ParserManager ready: ${ParserManager.instance.activeVersion} '
      '(${ParserManager.instance.activeSourceLabel})',
    );
  } catch (e) {
    await _log(channel, 'ParserManager init FAILED: $e');
  }

  // Step ①: parse only. Download chain is added in step ②.
  for (final raw in urls) {
    final url = raw.trim();
    if (url.isEmpty) continue;
    final sw = Stopwatch()..start();
    try {
      final outcome = await parsePostOutcome(url);
      await _log(
        channel,
        'PARSE OK (${sw.elapsedMilliseconds}ms) ${outcome.data.platform} '
        '"${outcome.data.title ?? ''}" items=${outcome.data.items.length} :: $url',
      );
    } on ParseFailure catch (e) {
      await _log(
        channel,
        'PARSE FAIL[${e.code}] (${sw.elapsedMilliseconds}ms) ${e.message} :: $url',
      );
    } catch (e) {
      await _log(channel, 'PARSE ERR (${sw.elapsedMilliseconds}ms) $e :: $url');
    }
  }

  try {
    await channel.invokeMethod<void>('idle');
  } catch (_) {}
}
