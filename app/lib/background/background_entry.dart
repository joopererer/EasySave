// v1.6 background task host. Runs in the FlutterEngine started by HostService
// (no Activity). Handles a submitted task end-to-end: extract link → parse →
// download → save to album → write history, then asks the native side to
// refresh the main UI / show an error notification.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../core/dev_log.dart';
import '../core/models.dart';
import '../core/media_request.dart';
import '../services/media_request_policy.dart';
import '../services/site_registry.dart';
import '../services/download_manager.dart';
import '../services/download_claims.dart';
import '../services/gallery_locator_service.dart';
import '../services/links.dart';
import '../services/parse_service.dart';
import '../services/preview_resources.dart';
import '../services/shared_preview_cache.dart';
import '../services/settings.dart';
import '../services/update_service.dart';

const String _channelName = 'easysave/bgtask';

/// Pending "选择下载" panel: completed by the native panel's result callback.
Completer<List<int>?>? _selectCompleter;

/// Entry point executed by [HostService]'s FlutterEngine (see `backgroundMain`
/// in `main.dart`).
void backgroundEntry() {
  WidgetsFlutterBinding.ensureInitialized();
  // This isolate owns the batches it starts: it is the only one allowed to
  // save them to the album and write their history record (the main isolate
  // reads the same SharedPreferences snapshots and must ignore them).
  DownloadManager.owner = DownloadBatch.sourceBackground;
  final channel = MethodChannel(_channelName);
  channel.setMethodCallHandler((call) async {
    switch (call.method) {
      case 'submit':
        await _handleSubmit(channel, (call.arguments as Map?) ?? const {});
        break;
      case 'selectResult':
        final args = (call.arguments as Map?) ?? const {};
        final raw = args['indices'] as List?;
        final picked = raw == null
            ? null
            : [for (final e in raw) (e as num).toInt()];
        final c = _selectCompleter;
        _selectCompleter = null;
        if (c != null && !c.isCompleted) c.complete(picked);
        break;
      case 'mediaPolicyRejected':
        final values = call.arguments as Map? ?? const {};
        final code = values['code'] as String? ?? 'REQUEST_URL_REJECTED';
        final host = values['host'] as String? ?? '';
        final field = values['field'] as String? ?? '';
        final shape = values['shape'] as String? ?? '';
        if (RegExp(r'^REQUEST_[A-Z_]+$').hasMatch(code) &&
            RegExp(r'^[a-z0-9.:-]{0,253}$').hasMatch(host) &&
            RegExp(
              r'^(thumbRequest|imageRequest|videoRequest)$',
            ).hasMatch(field) &&
            RegExp(
              r'^(empty|relative|protocol-relative|scheme=[a-z][a-z0-9+.-]*)$',
            ).hasMatch(shape)) {
          await DevLog.write(
            'RequestPolicy',
            '$code host=$host${code == 'REQUEST_URL_REJECTED' ? ' field=$field shape=$shape' : ''}',
          );
        }
        break;
    }
    return null;
  });
  channel.invokeMethod('ready');
}

Future<void> _invoke(
  MethodChannel channel,
  String method, [
  dynamic args,
]) async {
  try {
    await channel.invokeMethod<void>(method, args);
  } catch (_) {
    // Channel may be gone; nothing else we can do in a headless isolate.
  }
}

/// Log to the native sink. The message is scrubbed first: URLs lose their
/// query parameters (xsec_token, share_id, ...) and cookie/token-ish values
/// are redacted, so nothing sensitive can reach logcat.
Future<void> _log(MethodChannel channel, String msg) =>
    _invoke(channel, 'log', DevLog.scrub(msg));

Future<void> _notify(MethodChannel channel, String msg) =>
    _invoke(channel, 'notify', msg);

/// Quick, glanceable feedback for a background download (share / tile /
/// bubble). Gated by the user's "后台下载结果提示" setting.
Future<void> _toast(MethodChannel channel, String msg) =>
    _invoke(channel, 'toast', msg);

/// Error notification that carries the link + code + message so tapping it can
/// open the app on the same error page as a manual parse.
Future<void> _error(
  MethodChannel channel,
  String url,
  String code,
  String message,
) => _invoke(channel, 'error', {'url': url, 'code': code, 'message': message});

/// Drive the Quick Settings tile state (active + subtitle).
Future<void> _tile(MethodChannel channel, bool active, String? subtitle) =>
    _invoke(channel, 'tile', {'active': active, 'subtitle': subtitle});

/// Drive the floating bubble state (with optional error details so tapping the
/// error bubble can open the same error page as a manual parse).
Future<void> _bubble(
  MethodChannel channel,
  bool active,
  int done,
  int total,
  String? label,
  bool error, [
  String? url,
  String? code,
  String? message,
]) => _invoke(channel, 'bubble', {
  'active': active,
  'done': done,
  'total': total,
  'label': label,
  'error': error,
  'url': url,
  'code': code,
  'message': message,
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

Future<void> _handleSubmit(
  MethodChannel channel,
  Map<dynamic, dynamic> args,
) async {
  final mode = args['mode']?.toString() ?? 'all';
  final source = args['source']?.toString() ?? 'background';
  final text = args['text']?.toString();
  var urls = (args['urls'] as List?)?.map((e) => '$e').toList() ?? <String>[];
  if (urls.isEmpty && text != null && text.isNotEmpty) {
    urls = extractLinks(text);
  }
  await _log(channel, 'submit: mode=$mode urls=${urls.length} source=$source');
  await _invoke(channel, 'keepAlive');
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

  try {
    await ParserManager.instance.init();
  } catch (e) {
    await _log(channel, 'ParserManager init FAILED type=${e.runtimeType}');
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
      final outcome = await parsePostOutcome(
        url,
        source: mode == 'select' ? 'bubble_select' : 'bubble_background',
        onCacheMiss: () async {
          await _notify(channel, '正在解析…');
          await _tile(channel, true, '解析中…');
          await _bubble(channel, true, 0, 0, '解析中…', false);
        },
      );
      final post = outcome.data;
      if (mode == 'caption') {
        final cap = _captionText(post);
        // The headless engine has no PlatformPlugin, so Clipboard.setData would
        // hang; set it natively via HostService instead.
        await _invoke(channel, 'clipboard', cap);
        await _log(channel, 'CAPTION copied ${cap.length} chars');
        anyStarted = true;
        await _tile(channel, false, null);
        await _bubble(channel, false, 1, 1, null, false);
        if (toasts) await _toast(channel, '文案已复制');
        await _notify(channel, '文案已复制到剪贴板');
        await _invoke(channel, 'idle');
        continue;
      }
      if (mode == 'select') {
        if (post.items.isEmpty) {
          await _notify(channel, '该帖子没有可保存的内容');
          break;
        }
        final completer = Completer<List<int>?>();
        _selectCompleter = completer;
        // Which items of this post were already downloaded (so the panel can
        // mark them and the user can just fetch what is missing).
        final savedIdx = <int>{};
        try {
          savedIdx.addAll(
            await GalleryLocatorService.instance.findDownloadedIndices(post),
          );
        } catch (e) {
          await _log(
            channel,
            'SELECT history lookup failed type=${e.runtimeType}',
          );
        }
        final site = SiteRegistry.current.byId(post.platform);
        if (site == null) {
          throw const MediaPolicyException('REQUEST_SITE_REJECTED', '');
        }
        final mediaPolicy = MediaRequestPolicy(site);
        Future<Map<String, Object?>> nativeRequirement(
          MediaRequestResource resource,
          String identity,
        ) async {
          final uri = mediaPolicy.validate(resource);
          if (resource.role == MediaResourceRole.image ||
              resource.role == MediaResourceRole.poster ||
              (resource.role == MediaResourceRole.fallback &&
                  resource.fallbackFor != MediaResourceRole.video)) {
            return {
              'cacheIdentity': safeCacheLabel(identity),
              'cacheKey': opaquePreviewKey(identity),
              if (resource.request.expiresAt != null)
                'expiresAtMs':
                    resource.request.expiresAt!.millisecondsSinceEpoch,
              'sharedImageKey': SharedThumbnailCache.instance.registerResource(
                mediaPolicy,
                resource,
                identity: identity,
              ),
            };
          }

          final requiresCookie = resource.request.cookieDomains.any(
            (domain) => uri.host == domain || uri.host.endsWith('.$domain'),
          );
          if (requiresCookie) return {'requiresAppPreview': true};
          final authorized = await mediaPolicy.authorize(resource);
          return {
            'url': authorized.uri.toString(),
            'headers': authorized.headers,
            'mediaHosts': (site.data['download'] as Map)['mediaHosts'],
            if (resource.request.expiresAt != null)
              'expiresAtMs': resource.request.expiresAt!.millisecondsSinceEpoch,
          };
        }

        final panelItems = <Map<String, Object?>>[];
        for (var i = 0; i < post.items.length; i++) {
          final item = post.items[i];
          final identity = thumbnailIdentity(
            post.platform,
            post.id,
            item.cacheItemIndex ?? i,
            item.type == 'video' ? 'poster' : 'thumb',
          );
          final resources = mediaPolicy.resourcesFor(item);
          final thumbUrl = item.type != 'video'
              ? item.url
              : item.posterUrl != null &&
                    item.posterUrl != item.url &&
                    item.posterUrl != item.videoUrl
              ? item.posterUrl
              : item.videoUrl != null && item.videoUrl != item.url
              ? item.url
              : null;
          Future<Map<String, Object?>> forUrl(String? url) async {
            if (url == null || url.isEmpty) return {'requiresAppPreview': true};
            final resource = resources.where((r) => r.url == url).firstOrNull;
            if (resource == null) {
              mediaPolicy.rejectResource(url);
            }
            return nativeRequirement(resource, identity);
          }

          Future<List<Map<String, Object?>>> imageFallbacks(String? url) async {
            final candidates = previewImageCandidates(resources, url);
            return [
              for (final resource in candidates.skip(1))
                await nativeRequirement(resource, identity),
            ];
          }

          panelItems.add({
            'thumbRequest': await forUrl(thumbUrl),
            'imageRequest': await forUrl(item.url),
            'thumbFallbacks': await imageFallbacks(thumbUrl),
            'imageFallbacks': await imageFallbacks(item.url),
            'videoRequest': await forUrl(item.videoUrl ?? item.url),
            'video': item.type == 'video',
            'live':
                item.type == 'live' &&
                item.videoUrl != null &&
                item.videoUrl!.isNotEmpty,
            'openOnHold': post.platform == 'tiktok' && item.type == 'video',
            'saved': savedIdx.contains(i),
          });
        }
        await _invoke(channel, 'showSelectPanel', {
          'stickyPreview': settings.bubblePreviewSticky,
          'postUrl': url,
          'items': panelItems,
        });
        // Keep the engine alive while the user picks.
        final picker = Timer.periodic(
          const Duration(seconds: 20),
          (_) => _invoke(channel, 'keepAlive'),
        );
        final selected = await completer.future;
        picker.cancel();
        _selectCompleter = null;
        await _invoke(channel, 'unmountSelectPanel');
        if (selected == null || selected.isEmpty) {
          await _log(channel, 'SELECT cancelled');
          await _tile(channel, false, null);
          await _bubble(channel, false, 0, 0, null, false);
          await _invoke(channel, 'idle');
          break;
        }
        final author = post.author.name ?? '';
        final batch = await manager.startBatch(
          post,
          selected,
          album: settings.albumName,
          nameFor: (label, seq, ext) =>
              settings.fileName(postId: post.id, seq: seq, author: author),
          requestGalleryAccess: false,
        );
        anyStarted = true;
        await _log(
          channel,
          'DOWNLOAD started ${batch.jobs.length} files (selected)',
        );
        if (toasts) await _toast(channel, '开始下载 ${batch.jobs.length} 个文件');
        unawaited(_awaitBatchAndNotify(channel, batch, started, url, toasts));
        break;
      }
      if (post.items.isEmpty) {
        await _log(
          channel,
          'PARSE OK but no items (${sw.elapsedMilliseconds}ms)',
        );
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
      await _log(channel, 'DOWNLOAD started ${batch.jobs.length} files');
      if (toasts) await _toast(channel, '开始下载 ${batch.jobs.length} 个文件');
      unawaited(_awaitBatchAndNotify(channel, batch, started, url, toasts));
    } on AlreadyDownloading {
      if (toasts) await _toast(channel, '已在下载中');
      await _tile(channel, false, null);
      await _bubble(channel, false, 0, 0, null, false);
      await _invoke(channel, 'idle');
      // This request is handled by an existing batch, not a parse failure.
      anyStarted = true;
    } on ParseFailure catch (e) {
      await _log(
        channel,
        'PARSE FAIL[${e.code}] (${sw.elapsedMilliseconds}ms)',
      );
      if (e.code == ParseErrorCode.loginRequired) {
        if (toasts) await _toast(channel, '需要登录：${e.message}');
      } else if (toasts) {
        await _toast(channel, '解析失败：${e.message}');
      }
      await _tile(channel, false, null);
      await _bubble(channel, false, 0, 0, null, true, url, e.code, e.message);
      await _error(channel, url, e.code, e.message);
    } on MediaPolicyException catch (e) {
      await _log(channel, 'REQUEST POLICY ${e.code} host=${e.host}');
      if (toasts) await _toast(channel, '该资源地址不在允许范围内');
      await _tile(channel, false, null);
      await _bubble(
        channel,
        false,
        0,
        0,
        null,
        true,
        null,
        e.code,
        '该资源地址不在允许范围内',
      );
      await _error(channel, '', e.code, '该资源地址不在允许范围内');
    } catch (e) {
      await _log(
        channel,
        'ERROR (${sw.elapsedMilliseconds}ms) type=${e.runtimeType}',
      );
      if (toasts) await _toast(channel, '处理失败');
      await _tile(channel, false, null);
      await _bubble(
        channel,
        false,
        0,
        0,
        null,
        true,
        url,
        ParseErrorCode.invalidPage,
        '$e',
      );
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
          batch.jobs.firstWhere((j) => j.state == JobState.failed).error ??
          '下载失败';
      await _log(
        channel,
        'DOWNLOAD failed: $ok/$total ok, $failed failed, ${secs}s',
      );
      if (toasts) await _toast(channel, '下载失败：成功 $ok/$total');
      await _notify(channel, '下载失败：成功 $ok/$total —— $firstError');
    } else {
      await _log(channel, 'DOWNLOAD done: $ok/$total in ${secs}s');
      if (toasts) await _toast(channel, '下载完成：$ok/$total 个文件');
      await _notify(channel, '下载完成：$ok/$total 个文件');
    }
    await _invoke(channel, 'historyChanged');
  } finally {
    keepAlive.cancel();
    await _tile(channel, false, null);
    await _bubble(
      channel,
      false,
      batch.succeeded,
      total,
      null,
      failed > 0,
      failed > 0 ? url : null,
      failed > 0 ? ParseErrorCode.invalidPage : null,
      failed > 0 ? '下载失败' : null,
    );
    await _invoke(channel, 'idle');
  }
}
