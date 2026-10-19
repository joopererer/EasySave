// v1.6 background task host. Runs in the FlutterEngine started by HostService
// (no Activity). Handles a submitted task end-to-end: extract link → parse →
// download → save to album → write history, then asks the native side to
// refresh the main UI / show an error notification.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../core/models.dart';
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

/// Quick, glanceable feedback for a background download (share / tile /
/// bubble). Gated by the user's "后台下载结果提示" setting.
Future<void> _toast(MethodChannel channel, String msg) =>
    _invoke(channel, 'toast', msg);

/// Error notification that carries the link + code + message so tapping it can
/// open the app on the same error page as a manual parse.
Future<void> _error(MethodChannel channel, String url, String code, String message) =>
    _invoke(channel, 'error', {'url': url, 'code': code, 'message': message});

/// Drive the Quick Settings tile state (active + subtitle).
Future<void> _tile(MethodChannel channel, bool active, String? subtitle) =>
    _invoke(channel, 'tile', {'active': active, 'subtitle': subtitle});

/// Drive the floating bubble state.
Future<void> _bubble(
  MethodChannel channel,
  bool active,
  int done,
  int total,
  String? label,
  bool error,
) =>
    _invoke(channel, 'bubble', {
      'active': active,
      'done': done,
      'total': total,
      'label': label,
      'error': error,
    });

/// Build the caption text (title + body) for the bubble's "复制文案".
String _captionText(ParsedPost post) {
  final parts = <String>[];
  final t = post.title?.trim() ?? '';
  if (t.isNotEmpty) parts.add(t);
  final c = post.caption?.trim() ?? '';
  if (c.isNotEmpty) parts.add(c);
  return parts.join('\n\n');
}

Future<void> _handleSubmit(MethodChannel channel, Map<dynamic, dynamic> args) async {  final mode = args['mode']?.toString() ?? 'all';
  final source = args['source']?.toString() ?? 'background';
  final text = args['text']?.toString();
  var urls = (args['urls'] as List?)?.map((e) => '$e').toList() ?? <String>[];
  if (urls.isEmpty && text != null && text.isNotEmpty) {
    urls = extractLinks(text);
  }
  await _log(channel, 'submit: mode=$mode urls=${urls.length} source=$source');
  await _invoke(channel, 'keepAlive');
  await _notify(channel, '正在解析…');
  final settings = await AppSettings.load();
  final toasts = settings.backgroundToast;
  final emptyHint = args['hint']?.toString() ?? '没有可解析的链接';

  if (urls.isEmpty) {
    await _log(channel, 'no supported link in input');
    await _invoke(channel, 'toast', emptyHint);
    await _invoke(channel, 'stop');
    return;
  }
  if (toasts) await _toast(channel, '下载准备中…');
  await _tile(channel, true, '解析中…');
  await _bubble(channel, true, 0, 0, '解析中…', false);

  try {
    await ParserManager.instance.init();
  } catch (e) {
    await _log(channel, 'ParserManager init FAILED: $e');
  }

  final manager = DownloadManager.instance;
  await manager.init();

  var anyStarted = false;
  for (final raw in urls) {
    final url = raw.trim();
    if (url.isEmpty) continue;
    final started = DateTime.now();
    final sw = Stopwatch()..start();
    try {
      final outcome = await parsePostOutcome(url);
      final post = outcome.data;
      if (mode == 'caption') {
        final cap = _captionText(post);
        await Clipboard.setData(ClipboardData(text: cap));
        await _log(channel, 'CAPTION copied ${cap.length} chars :: $url');
        anyStarted = true;
        await _tile(channel, false, null);
        await _bubble(channel, false, 1, 1, null, false);
        if (toasts) await _toast(channel, '文案已复制');
        await _notify(channel, '文案已复制到剪贴板');
        await _invoke(channel, 'idle');
        continue;
      }
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
      await _log(channel, 'DOWNLOAD started ${batch.jobs.length} files :: $url');
      if (toasts) await _toast(channel, '开始下载 ${batch.jobs.length} 个文件');
      unawaited(_awaitBatchAndNotify(channel, batch, started, url, toasts));
    } on ParseFailure catch (e) {
      await _log(channel, 'PARSE FAIL[${e.code}] (${sw.elapsedMilliseconds}ms) ${e.message} :: $url');
      if (toasts) await _toast(channel, '解析失败：${e.message}');
      await _tile(channel, false, null);
      await _bubble(channel, false, 0, 0, null, true);
      await _error(channel, url, e.code, e.message);
    } catch (e) {
      await _log(channel, 'ERROR (${sw.elapsedMilliseconds}ms) $e :: $url');
      if (toasts) await _toast(channel, '处理失败');
      await _tile(channel, false, null);
      await _bubble(channel, false, 0, 0, null, true);
      await _error(channel, url, ParseErrorCode.invalidPage, '$e');
    }
  }

  if (!anyStarted) {
    await _tile(channel, false, null);
    await _bubble(channel, false, 0, 0, null, true);
    await _invoke(channel, 'idle');
  }
}

/// Keep the engine alive while the batch downloads, then report the outcome
/// (log + notification), ask the UI to refresh, and go idle.
Future<void> _awaitBatchAndNotify(
  MethodChannel channel,
  DownloadBatch batch,
  DateTime started,
  String url,
  bool toasts,
) async {
  final keepAlive = Timer.periodic(
    const Duration(seconds: 20),
    (_) => _invoke(channel, 'keepAlive'),
  );
  final total = batch.jobs.length;
  var lastDone = -1;
  var failed = 0;
  try {
    while (!batch.isTerminal) {
      final done = batch.succeeded;
      if (done != lastDone) {
        lastDone = done;
        await _tile(channel, true, '$done/$total');
        await _bubble(channel, true, done, total, null, false);
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    // Give _afterTerminal() (gallery link + history write) time to run.
    await Future<void>.delayed(const Duration(milliseconds: 1000));
    final ok = batch.succeeded;
    failed = batch.jobs.where((j) => j.state == JobState.failed).length;
    final secs = DateTime.now().difference(started).inSeconds;
    if (failed > 0) {
      final firstError =
          batch.jobs.firstWhere((j) => j.state == JobState.failed).error ?? '下载失败';
      await _log(channel, 'DOWNLOAD failed: $ok/$total ok, $failed failed, ${secs}s :: $url');
      if (toasts) await _toast(channel, '下载失败：成功 $ok/$total');
      await _notify(channel, '下载失败：成功 $ok/$total —— $firstError');
    } else {
      await _log(channel, 'DOWNLOAD done: $ok/$total in ${secs}s :: $url');
      if (toasts) await _toast(channel, '下载完成：$ok/$total 个文件');
      await _notify(channel, '下载完成：$ok/$total 个文件');
    }
    await _invoke(channel, 'historyChanged');
  } finally {
    keepAlive.cancel();
    await _tile(channel, false, null);
    await _bubble(channel, false, batch.succeeded, total, null, failed > 0);
    await _invoke(channel, 'idle');
  }
}
