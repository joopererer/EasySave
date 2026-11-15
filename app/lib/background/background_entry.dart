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
import '../services/history_db.dart';
import '../services/links.dart';
import '../services/network_status.dart';
import '../services/parse_service.dart';
import '../services/preview_resources.dart';
import '../services/shared_preview_cache.dart';
import '../services/settings.dart';
import '../services/update_service.dart';

const String _channelName = 'easysave/bgtask';

/// Deadlines for every await on a native channel in a background task
/// (v1.11 batch 3).
///
/// Build 55 device report: after the background engine had been destroyed for
/// being idle and then rebuilt, a submitted task logged `submit: mode=select
/// urls=1 source=bubble` and nothing else — no ShortLink, no ParseWebView, no
/// batch — while the notification stayed on 「准备中」. Any await on a channel
/// the rebuilt engine had not (re)registered, or on a platform call that never
/// answers, stops the whole task silently, because the step after it never
/// runs and nobody ever calls `idle`.
///
/// Now every such await has a deadline and a safe default, and every step logs
/// how long it took, so the log says exactly where a task stalled.
@visibleForTesting
Duration backgroundNativeTimeout = const Duration(seconds: 3);

@visibleForTesting
Duration backgroundStepTimeout = const Duration(seconds: 10);

/// Longest a parse may take before the task gives up on that link. Parsing is
/// not a channel call (it drives a WebView), so it gets its own budget.
const Duration _parseTimeout = Duration(seconds: 120);

// Test seams (v1.11 batch 3): let a test drive the submit pipeline — including
// a rebuilt engine — without a device, a network or a WebView.
@visibleForTesting
Future<AppSettings> Function()? backgroundSettingsForTesting;

@visibleForTesting
Future<void> Function()? backgroundParserInitForTesting;

@visibleForTesting
Future<void> Function()? backgroundDownloadsInitForTesting;

@visibleForTesting
Future<ParsedPost> Function(
  String url, {
  required String source,
  Future<void> Function()? onCacheMiss,
})?
backgroundParseForTesting;

@visibleForTesting
Future<DownloadBatch> Function(
  ParsedPost post,
  List<int> indices,
  AppSettings settings,
)?
backgroundStartBatchForTesting;

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
  HistoryDb.engine = 'background';
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
    await channel
        .invokeMethod<void>(method, args)
        .timeout(backgroundNativeTimeout);
  } on TimeoutException {
    // A channel that is silent must not stop the task; DevLog has its own
    // guard, so this line cannot hang either.
    unawaited(
      DevLog.write(
        'BgTask',
        'event=native_timeout call=$method '
            'after=${backgroundNativeTimeout.inMilliseconds}ms',
      ),
    );
  } catch (_) {
    // Channel may be gone; nothing else we can do in a headless isolate.
  }
}

/// Runs one startup step (a native channel, a plugin, a settings read) with a
/// deadline and a safe default.
///
/// Returns null when the step timed out or failed; the caller then continues
/// with what it has, exactly as if the step had reported "unknown". Nothing
/// here decides behaviour beyond that default.
Future<T?> _step<T>(
  MethodChannel channel,
  String name,
  Future<T> Function() run, {
  Duration? timeout,
}) async {
  final watch = Stopwatch()..start();
  try {
    final value = await run().timeout(timeout ?? backgroundStepTimeout);
    unawaited(_log(channel, 'step=$name ok ${watch.elapsedMilliseconds}ms'));
    return value;
  } on TimeoutException {
    unawaited(
      _log(
        channel,
        'step=$name TIMEOUT after=${watch.elapsedMilliseconds}ms '
        '-> safe default',
      ),
    );
    return null;
  } catch (e) {
    unawaited(
      _log(
        channel,
        'step=$name FAILED type=${e.runtimeType} '
        'after=${watch.elapsedMilliseconds}ms -> safe default',
      ),
    );
    return null;
  }
}

/// The app's parse entry point; a test replaces it through
/// [backgroundParseForTesting].
Future<ParsedPost> _parsePost(
  String url, {
  required String source,
  Future<void> Function()? onCacheMiss,
}) async {
  final injected = backgroundParseForTesting;
  if (injected != null) {
    return injected(url, source: source, onCacheMiss: onCacheMiss);
  }
  final outcome = await parsePostOutcome(
    url,
    source: source,
    onCacheMiss: onCacheMiss,
  );
  return outcome.data;
}

/// Starts the batch through [DownloadManager]; a test replaces it through
/// [backgroundStartBatchForTesting].
Future<DownloadBatch> _startBatch(
  ParsedPost post,
  List<int> indices,
  AppSettings settings,
) {
  final injected = backgroundStartBatchForTesting;
  if (injected != null) return injected(post, indices, settings);
  final author = post.author.name ?? '';
  return DownloadManager.instance.startBatch(
    post,
    indices,
    album: settings.albumName,
    nameFor: (label, seq, ext) =>
        settings.fileName(postId: post.id, seq: seq, author: author),
    requestGalleryAccess: false,
  );
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
  // Every step of a submit logs where it is: build 55 stopped right after this
  // line, and without the steps below the log could not say why.
  await _log(
    channel,
    'submit: step=received mode=$mode urls=${urls.length} source=$source',
  );
  await _invoke(channel, 'keepAlive');
  // A settings read that does not answer falls back to the defaults, so the
  // task continues (album name, name pattern and toast setting are all the
  // same values a fresh install uses).
  final settings =
      await _step<AppSettings>(
        channel,
        'settings',
        () => backgroundSettingsForTesting?.call() ?? AppSettings.load(),
      ) ??
      AppSettings();
  final toasts = settings.backgroundToast;
  final emptyHint = args['hint']?.toString() ?? '没有可解析的链接';

  if (urls.isEmpty) {
    await _log(channel, 'no supported link in input');
    await _invoke(channel, 'toast', emptyHint);
    await _invoke(channel, 'stop');
    return;
  }
  if (toasts) await _toast(channel, '下载准备中…');

  // Connectivity is display only; an unknown state counts as online and the
  // downloader decides for itself.
  await _step<void>(channel, 'network', () => NetworkStatus.instance.start());
  await _log(channel, 'step=network online=${NetworkStatus.instance.online}');

  await _step<void>(
    channel,
    'parser-init',
    () =>
        backgroundParserInitForTesting?.call() ?? ParserManager.instance.init(),
  );
  await _step<void>(
    channel,
    'downloads-init',
    () =>
        backgroundDownloadsInitForTesting?.call() ??
        DownloadManager.instance.init(),
  );

  var anyStarted = false;
  for (final raw in urls) {
    final url = raw.trim();
    if (url.isEmpty) continue;
    final started = DateTime.now();
    final sw = Stopwatch()..start();
    try {
      await _log(
        channel,
        'step=parse begin source=${mode == 'select' ? 'bubble_select' : 'bubble_background'}',
      );
      final post = await _parsePost(
        url,
        source: mode == 'select' ? 'bubble_select' : 'bubble_background',
        onCacheMiss: () async {
          await _notify(channel, '正在解析…');
          await _tile(channel, true, '解析中…');
          await _bubble(channel, true, 0, 0, '解析中…', false);
        },
      ).timeout(_parseTimeout);
      await _log(channel, 'step=parse done ${sw.elapsedMilliseconds}ms');
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
        final savedAssets = <int, String>{};
        try {
          final found = await GalleryLocatorService.instance
              .findDownloadedAssets(post, refreshAlbum: true)
              .timeout(backgroundStepTimeout);
          for (final entry in found.entries) {
            savedIdx.add(entry.key);
            final id = entry.value.id;
            if (id.isNotEmpty) savedAssets[entry.key] = id;
          }
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
          final thumbUrl =
              item.thumbnailUrl ??
              (item.type != 'video'
                  ? item.url
                  : item.posterUrl != null &&
                        item.posterUrl != item.url &&
                        item.posterUrl != item.videoUrl
                  ? item.posterUrl
                  : item.videoUrl != null && item.videoUrl != item.url
                  ? item.url
                  : null);
          final fullIdentity = item.thumbnailUrl == null
              ? identity
              : thumbnailIdentity(post.platform, post.id, i, 'image');
          Future<Map<String, Object?>> forUrl(
            String? url, {
            bool full = false,
          }) async {
            if (url == null || url.isEmpty) return {'requiresAppPreview': true};
            final resource = resources.where((r) => r.url == url).firstOrNull;
            if (resource == null) {
              mediaPolicy.rejectResource(url);
            }
            return nativeRequirement(resource, full ? fullIdentity : identity);
          }

          Future<List<Map<String, Object?>>> imageFallbacks(
            String? url, {
            bool full = false,
          }) async {
            final candidates = previewImageCandidates(resources, url);
            return [
              for (final resource in candidates.skip(1))
                await nativeRequirement(
                  resource,
                  full ? fullIdentity : identity,
                ),
            ];
          }

          panelItems.add({
            'thumbRequest': await forUrl(thumbUrl),
            'imageRequest': await forUrl(item.url, full: true),
            'thumbFallbacks': await imageFallbacks(thumbUrl),
            'imageFallbacks': await imageFallbacks(item.url, full: true),
            'videoRequest': await forUrl(item.videoUrl ?? item.url),
            'video': item.type == 'video',
            'live':
                item.type == 'live' &&
                item.videoUrl != null &&
                item.videoUrl!.isNotEmpty,
            'openOnHold': post.platform == 'tiktok' && item.type == 'video',
            'saved': savedIdx.contains(i),
            // MediaStore id of the saved copy: the panel opens that file
            // directly for a fullscreen preview instead of fetching the
            // original again.
            if (savedAssets[i] != null) 'savedMediaId': savedAssets[i],
          });
        }
        await _invoke(channel, 'showSelectPanel', {
          'stickyPreview': settings.bubblePreviewSticky,
          'postUrl': url,
          'postTitle': post.title,
          'aiLabel': post.aiLabel?.toJson(),
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
        final batch = await _step<DownloadBatch>(
          channel,
          'batch-start',
          () => _startBatch(post, selected, settings),
        );
        if (batch == null) {
          await _log(channel, 'step=batch-start gave up');
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
            '开始下载失败',
          );
          await _error(channel, url, ParseErrorCode.invalidPage, '开始下载失败');
          break;
        }
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
      final batch = await _step<DownloadBatch>(
        channel,
        'batch-start',
        () => _startBatch(post, [
          for (var i = 0; i < post.items.length; i++) i,
        ], settings),
      );
      if (batch == null) {
        await _log(channel, 'step=batch-start gave up');
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
          '开始下载失败',
        );
        await _error(channel, url, ParseErrorCode.invalidPage, '开始下载失败');
        continue;
      }
      anyStarted = true;
      await _log(channel, 'DOWNLOAD started ${batch.jobs.length} files');
      if (toasts) await _toast(channel, '开始下载 ${batch.jobs.length} 个文件');
      unawaited(_awaitBatchAndNotify(channel, batch, started, url, toasts));
    } on TimeoutException {
      await _log(
        channel,
        'step=parse TIMEOUT after=${_parseTimeout.inSeconds}s',
      );
      if (toasts) await _toast(channel, '解析超时，请重试');
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
        '解析超时',
      );
      await _error(channel, url, ParseErrorCode.invalidPage, '解析超时');
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
      final firstFailed = batch.jobs.firstWhere(
        (j) => j.state == JobState.failed,
      );
      // Never the raw exception ("Bad state: …") in a notification: the
      // download manager already stores a per-item sentence, and history uses
      // shortFailureReason() for the same reason.
      final firstError = userFacingFailureReason(firstFailed);
      await _log(
        channel,
        'DOWNLOAD failed: $ok/$total ok, $failed failed, ${secs}s',
      );
      if (toasts) await _toast(channel, '下载失败：成功 $ok/$total');
      await _notify(channel, '下载失败：成功 $ok/$total —— $firstError');
    } else {
      await _log(channel, 'DOWNLOAD done: $ok/$total in ${secs}s');
      // 图片格式 (v1.11 batch 3): say when the original bytes were kept in a
      // container this device may not display, or when JPEG was asked for and
      // no jpeg candidate existed.
      final formatNote = imageFormatCompletionNote(batch);
      if (toasts) {
        await _toast(
          channel,
          formatNote == null
              ? '下载完成：$ok/$total 个文件'
              : '下载完成：$ok/$total 个文件 · $formatNote',
        );
      }
      await _notify(
        channel,
        formatNote == null
            ? '下载完成：$ok/$total 个文件'
            : '下载完成：$ok/$total 个文件 —— $formatNote',
      );
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
