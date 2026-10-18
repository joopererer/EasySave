// v1.6 background task host. Runs in the FlutterEngine started by HostService
// (no Activity). Handles a submitted task end-to-end: extract link → parse →
// download → save to album → write history, then asks the native side to
// refresh the main UI and to update the notification.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:gal/gal.dart';

import '../services/download_manager.dart';
import '../services/links.dart';
import '../services/parse_service.dart';
import '../services/settings.dart';
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

Future<void> _invoke(MethodChannel channel, String method, [dynamic args]) async {
  try {
    await channel.invokeMethod<void>(method, args);
  } catch (_) {
    // Channel may be gone; nothing else we can do in a headless isolate.
  }
}

Future<void> _log(MethodChannel channel, String msg) =>
    _invoke(channel, 'log', msg);

Future<void> _notify(MethodChannel channel, String msg) =>
    _invoke(channel, 'notify', msg);

Future<void> _handleSubmit(MethodChannel channel, Map<dynamic, dynamic> args) async {
  final mode = args['mode']?.toString() ?? 'all';
  final source = args['source']?.toString() ?? 'background';
  final text = args['text']?.toString();
  var urls = (args['urls'] as List?)?.map((e) => '$e').toList() ?? <String>[];
  if (urls.isEmpty && text != null && text.isNotEmpty) {
    urls = extractLinks(text);
  }
  await _log(channel, 'submit: mode=$mode urls=${urls.length} source=$source');
  await _invoke(channel, 'keepAlive');

  if (urls.isEmpty) {
    await _log(channel, 'no supported link in input');
    await _notify(channel, '未找到可下载的链接');
    await _invoke(channel, 'idle');
    return;
  }

  try {
    await ParserManager.instance.init();
  } catch (e) {
    await _log(channel, 'ParserManager init FAILED: $e');
  }

  // The background flow must never raise a system permission dialog.
  if (!await Gal.hasAccess()) {
    await _log(channel, 'NO_GALLERY_ACCESS');
    await _notify(channel, '请先打开 EasySave 授权相册');
    await _invoke(channel, 'idle');
    return;
  }

  final settings = await AppSettings.load();
  final manager = DownloadManager.instance;
  await manager.init();

  var anyStarted = false;
  for (final raw in urls) {
    final url = raw.trim();
    if (url.isEmpty) continue;
    final sw = Stopwatch()..start();
    try {
      final outcome = await parsePostOutcome(url);
      final post = outcome.data;
      if (post.items.isEmpty) {
        await _log(channel, 'PARSE OK but no items (${sw.elapsedMilliseconds}ms) :: $url');
        await _notify(channel, '该帖子没有可保存的内容');
        continue;
      }
      final author = post.author.name ?? '';
      final batch = await manager.startBatch(
        post,
        [for (var i = 0; i < post.items.length; i++) i],
        album: settings.albumName,
        nameFor: (label, seq, ext) =>
            settings.fileName(postId: post.id, seq: seq, author: author),
        requestGalleryAccess: false,
      );
      anyStarted = true;
      await _log(
        channel,
        'DOWNLOAD started ${batch.jobs.length} files (${sw.elapsedMilliseconds}ms) :: $url',
      );
      unawaited(_awaitBatchAndNotify(channel, batch));
    } on ParseFailure catch (e) {
      await _log(channel, 'PARSE FAIL[${e.code}] ${e.message} :: $url');
      await _notify(channel, '解析失败：${e.message}');
    } catch (e) {
      await _log(channel, 'ERROR $e :: $url');
      await _notify(channel, '处理失败：$e');
    }
  }

  if (!anyStarted) {
    await _invoke(channel, 'idle');
  }
}

/// Keep the engine alive while the batch downloads, then ask the UI to
/// refresh and go idle.
Future<void> _awaitBatchAndNotify(MethodChannel channel, DownloadBatch batch) async {
  final keepAlive = Timer.periodic(
    const Duration(seconds: 20),
    (_) => _invoke(channel, 'keepAlive'),
  );
  try {
    while (!batch.isTerminal) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    // Give _afterTerminal() (gallery link + history write) time to run.
    await Future<void>.delayed(const Duration(milliseconds: 1000));
    await _invoke(channel, 'historyChanged');
    await _notify(channel, '下载完成：${batch.succeeded}/${batch.jobs.length} 个文件');
  } finally {
    keepAlive.cancel();
    await _invoke(channel, 'idle');
  }
}
