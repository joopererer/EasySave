import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'thumbnail_header.dart';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../core/media_request.dart';
import '../core/models.dart';
import 'authorized_media_http.dart';
import 'media_request_policy.dart';
import 'site_registry.dart';
import '../core/dev_log.dart';

/// Bounded, short-lived Dart memory. The native bridge only transfers envelopes
/// between engines and never writes parsed posts to disk.
class SharedParseCache<T> {
  SharedParseCache({
    DateTime Function()? now,
    this.ttl = const Duration(minutes: 10),
    this.capacity = 8,
  }) : now = now ?? DateTime.now;
  final DateTime Function() now;
  final Duration ttl;
  final int capacity;
  final _entries =
      <String, ({T value, DateTime expires, Set<String> aliases})>{};
  void put(String canonicalId, T value, {Iterable<String> aliases = const []}) {
    _prune();
    _entries.remove(canonicalId);
    while (_entries.length >= capacity) {
      _entries.remove(_entries.keys.first);
    }
    _entries[canonicalId] = (
      value: value,
      expires: now().add(ttl),
      aliases: {canonicalId, ...aliases},
    );
  }

  T? get(String key) {
    _prune();
    for (final entry in _entries.values.toList().reversed) {
      if (entry.aliases.contains(key)) return entry.value;
    }
    return null;
  }

  /// Drop every entry [test] accepts, e.g. one site's posts after a login change.
  int removeWhere(bool Function(T value) test) {
    final drop = [
      for (final entry in _entries.entries)
        if (test(entry.value.value)) entry.key,
    ];
    for (final key in drop) {
      _entries.remove(key);
    }
    return drop.length;
  }

  void _prune() =>
      _entries.removeWhere((_, value) => !value.expires.isAfter(now()));
}

const sharedPreviewChannel = MethodChannel('easysave/shared_preview');
String opaquePreviewKey(String value) =>
    sha256.convert(utf8.encode(value)).toString();

String thumbnailIdentity(
  String platform,
  String postId,
  int index,
  String variant,
) => '${SiteRegistry.current.canonicalId(platform)}:$postId:$index:$variant';

String safeCacheLabel(String value) {
  if (RegExp(r'^[A-Za-z0-9_:.-]{1,180}$').hasMatch(value)) return value;
  return opaquePreviewKey(value).substring(0, 16);
}

/// Query-string expiry hints supplement the explicit signed request deadline.
DateTime? mediaUrlExpiry(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null) return null;
  for (final name in [
    'expires',
    'expire',
    'expiration',
    'x-expires',
    'Expires',
    'X-Expires',
  ]) {
    final raw = uri.queryParameters[name];
    final seconds = raw == null ? null : int.tryParse(raw);
    if (seconds != null && seconds > 0 && seconds <= 253402300799999)
      return DateTime.fromMillisecondsSinceEpoch(
        seconds > 100000000000 ? seconds : seconds * 1000,
        isUtc: true,
      );
  }
  final oe = uri.queryParameters['oe'];
  if (oe != null && RegExp(r'^[a-fA-F0-9]{8}$').hasMatch(oe)) {
    return DateTime.fromMillisecondsSinceEpoch(
      int.parse(oe, radix: 16) * 1000,
      isUtc: true,
    );
  }
  return null;
}

/// One authorized download implementation for both engines. Disk reads,
/// foreground downloads, validation and speculative work have separate budgets.
class SharedThumbnailCache {
  SharedThumbnailCache({
    http.Client? client,
    this.channel = sharedPreviewChannel,
    this.prefetchInterval = const Duration(milliseconds: 300),
  }) : client = client ?? http.Client();
  static final instance = SharedThumbnailCache();
  final http.Client client;
  final MethodChannel channel;
  final Duration prefetchInterval;
  final _pending = <String, Future<({Uint8List bytes, String? path})>>{};
  final _resources =
      <
        String,
        ({
          MediaRequestPolicy policy,
          MediaRequestResource resource,
          String identity,
        })
      >{};
  int _nextResource = 0;
  final _prefetched = <String, DateTime>{};
  final _prefetchQueue = <ParsedPost>[];
  bool _prefetching = false;

  Future<void> prefetch(ParsedPost post) async {
    final id = '${post.platform}:${post.id}';
    _prefetched.removeWhere((_, expires) => !expires.isAfter(DateTime.now()));
    if (_prefetched.containsKey(id)) return;
    _prefetched[id] = DateTime.now().add(const Duration(minutes: 10));
    if (_prefetched.length > 32) _prefetched.remove(_prefetched.keys.first);
    _prefetchQueue.add(post);
    if (_prefetching) return;
    _prefetching = true;
    try {
      while (_prefetchQueue.isNotEmpty) {
        final next = _prefetchQueue.removeAt(0);
        final site = SiteRegistry.current.byId(next.platform);
        if (site == null) continue;
        final policy = MediaRequestPolicy(site);
        for (var i = 0; i < next.items.length && i < 30; i++) {
          // Yield between speculative requests; visible requests start immediately
          // and have three download slots reserved while this one worker runs.
          await Future<void>.delayed(prefetchInterval);
          while (_pending.isNotEmpty) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          try {
            while (await channel.invokeMethod<bool>('thumbnailPrefetchIdle') ==
                false) {
              await Future<void>.delayed(const Duration(milliseconds: 50));
            }
            if (await channel.invokeMethod<bool>('thumbnailPrefetchAllowed') !=
                true) {
              _prefetched.remove('${next.platform}:${next.id}');
              break;
            }
            final item = next.items[i];
            final resources = policy
                .resourcesFor(item)
                .where(
                  (r) =>
                      r.role == MediaResourceRole.image ||
                      r.role == MediaResourceRole.poster ||
                      (r.role == MediaResourceRole.fallback &&
                          r.fallbackFor != MediaResourceRole.video),
                )
                .toList();
            final urls = item.type == 'video'
                ? [item.thumbnailUrl ?? item.posterUrl]
                : [
                    if (item.thumbnailUrl != null) item.thumbnailUrl!,
                    ...item.fallbacks,
                    item.url,
                  ];
            for (final url in urls) {
              final resource = resources.where((r) => r.url == url).firstOrNull;
              if (resource == null) continue;
              try {
                await load(
                  policy,
                  resource,
                  prefetch: true,
                  identity: thumbnailIdentity(
                    next.platform,
                    next.id,
                    i,
                    item.type == 'video' ? 'poster' : 'thumb',
                  ),
                );
                break;
              } catch (_) {
                /* Try the next declared candidate. */
              }
            }
          } on MissingPluginException {
            break;
          } catch (_) {
            /* Speculation must never fail parsing. */
          }
        }
      }
    } finally {
      _prefetching = false;
    }
  }

  static final decodeSlots = ThumbnailSlots(2);
  static final _downloadSlots = ThumbnailSlots(4);
  static final _prefetchSlots = ThumbnailSlots(1);
  static final _validationSlots = ThumbnailSlots(2);
  static final _prefetchValidationSlots = ThumbnailSlots(1);

  Future<void> _validate(
    Uint8List bytes, {
    bool prefetch = false,
    required String label,
  }) => (prefetch ? _prefetchValidationSlots : _validationSlots).run(
    () => compute(validateThumbnailHeader, bytes),
    event: 'validate',
    queue: prefetch ? 'prefetch' : 'write',
    key: label,
  );

  Future<void> _delete(String key) async {
    try {
      await channel.invokeMethod<void>('thumbnailDelete', {'key': key});
    } on MissingPluginException {
      /* No disk cache on this host. */
    }
  }

  Future<void> invalidate(String identity) =>
      _delete(opaquePreviewKey(identity));

  String registerResource(
    MediaRequestPolicy policy,
    MediaRequestResource resource, {
    String? identity,
  }) {
    policy.validate(resource);
    final label =
        identity ??
        '${policy.site.id}:unbound:${identityHashCode(resource)}:${resource.role.name}';
    final key = opaquePreviewKey('$label:${_nextResource++}');
    if (_resources.length >= 512) _resources.remove(_resources.keys.first);
    _resources[key] = (policy: policy, resource: resource, identity: label);
    channel.setMethodCallHandler((call) async {
      if (call.method != 'fetchThumbnail') return null;
      final entry = _resources[call.arguments as String];
      if (entry == null) return null;
      try {
        return (await load(
          entry.policy,
          entry.resource,
          identity: entry.identity,
        )).path;
      } catch (_) {
        return null;
      }
    });
    return key;
  }

  Future<({Uint8List bytes, String? path})> load(
    MediaRequestPolicy policy,
    MediaRequestResource resource, {
    String? identity,
    bool prefetch = false,
  }) async {
    policy.validate(resource);
    final label =
        identity ??
        '${policy.site.id}:unbound:${identityHashCode(resource)}:${resource.role.name}';
    final key = opaquePreviewKey(label);
    if (!prefetch) {
      try {
        await channel.invokeMethod<void>('thumbnailVisibleBegin', {'key': key});
      } on MissingPluginException {
        /* Non-Android host. */
      }
    }
    try {
      // Check committed files before admission to any download/validation queue.
      final cached = await _read(
        policy,
        resource,
        key,
        label,
        prefetch: prefetch,
      );
      if (cached != null) return cached;
      final afterRead = _pending[key];
      if (afterRead != null) return await afterRead;
      final future = _singleFlight(policy, resource, key, label, prefetch);
      _pending[key] = future;
      try {
        return await future;
      } finally {
        _pending.remove(key);
      }
    } finally {
      if (!prefetch) {
        try {
          await channel.invokeMethod<void>('thumbnailVisibleEnd', {'key': key});
        } on MissingPluginException {
          /* Non-Android host. */
        }
      }
    }
  }

  Future<({Uint8List bytes, String? path})> _singleFlight(
    MediaRequestPolicy policy,
    MediaRequestResource resource,
    String key,
    String label,
    bool prefetch,
  ) async {
    var acquired = false;
    try {
      try {
        // The native process arbitrates both Flutter engines. Waiters re-read
        // the committed file, or acquire ownership after a failed download.
        while (!acquired) {
          acquired =
              await channel.invokeMethod<bool>('thumbnailAcquire', {
                'key': key,
              }) ??
              true;
          if (!acquired) {
            final cached = await _read(
              policy,
              resource,
              key,
              label,
              prefetch: prefetch,
            );
            if (cached != null) return cached;
          }
        }
      } on MissingPluginException {
        /* Per-engine fallback for non-Android. */
      }
      for (var attempt = 0; ; attempt++) {
        try {
          return await _load(policy, resource, key, label, prefetch);
        } on MediaPolicyException {
          rethrow;
        } catch (_) {
          if (attempt >= 2) rethrow;
          await Future<void>.delayed(
            Duration(milliseconds: 250 * (attempt + 1)),
          );
        }
      }
    } finally {
      if (acquired)
        await channel.invokeMethod<void>('thumbnailRelease', {'key': key});
    }
  }

  Future<({Uint8List bytes, String? path})?> _read(
    MediaRequestPolicy policy,
    MediaRequestResource resource,
    String key,
    String label, {
    bool prefetch = false,
  }) async {
    final timer = Stopwatch()..start();
    var waitMs = 0;
    try {
      final info = await channel.invokeMethod<dynamic>('thumbnailRead', {
        'key': key,
        'label': safeCacheLabel(label),
        'timing': true,
        'prefetch': prefetch,
      });
      final String? path = info is Map
          ? info['path'] as String?
          : info as String?;
      final nativeIo = info is Map ? (info['ioMs'] as num?)?.toInt() ?? 0 : 0;
      waitMs = (timer.elapsedMilliseconds - nativeIo).clamp(
        0,
        timer.elapsedMilliseconds,
      );
      if (path == null) return null;
      final bytes = await File(path).readAsBytes();
      try {
        // Committed bytes were validated before atomic publication. Do not
        // re-decode hits or put reads behind validation of unrelated downloads.
        await compute(
          validateThumbnailHeader,
          bytes,
          debugLabel: 'thumbnail-header',
        );
      } catch (_) {
        await _delete(key);
        return null;
      }
      policy.validate(resource);
      unawaited(
        DevLog.write('ThumbCache', 'event=hit key=${safeCacheLabel(label)}'),
      );
      return (bytes: bytes, path: path);
    } on MissingPluginException {
      return null;
    } on FileSystemException {
      await _delete(key);
      return null;
    } finally {
      unawaited(
        DevLog.write(
          'ThumbLoad',
          'event=cache_read layer=dart queue=${prefetch ? 'prefetch' : 'read'} waitMs=$waitMs ioMs=${timer.elapsedMilliseconds - waitMs} ms=${timer.elapsedMilliseconds} key=${safeCacheLabel(label)}',
        ),
      );
    }
  }

  Future<({Uint8List bytes, String? path})> _load(
    MediaRequestPolicy policy,
    MediaRequestResource resource,
    String key,
    String label,
    bool prefetch,
  ) async {
    final cached = await _read(
      policy,
      resource,
      key,
      label,
      prefetch: prefetch,
    );
    if (cached != null) return cached;
    var speculative = prefetch;
    if (prefetch) {
      while (true) {
        bool idle = true;
        try {
          if (await channel.invokeMethod<bool>('thumbnailVisible', {
                'key': key,
              }) ==
              true) {
            speculative = false;
            break;
          }
          idle =
              await channel.invokeMethod<bool>('thumbnailPrefetchIdle', {
                'key': key,
              }) ??
              true;
        } on MissingPluginException {
          /* Non-Android host. */
        }
        if (idle) break;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
    final bytes = await (speculative ? _prefetchSlots : _downloadSlots).run(
      () => _download(policy, resource, label),
      event: 'network',
      queue: speculative ? 'prefetch' : 'download',
      key: label,
    );
    await _validate(bytes, prefetch: speculative, label: label);
    policy.validate(resource);
    String? path;
    try {
      final root = await channel.invokeMethod<String>('thumbnailDirectory');
      if (root != null) {
        final timer = Stopwatch()..start();
        final written = await compute(writeThumbnailFile, (
          root: root,
          key: key,
          bytes: bytes,
          origin: Isolate.current.controlPort,
        ), debugLabel: 'thumbnail-write');
        path = written.path;
        final waitMs = (timer.elapsedMilliseconds - written.ioMs).clamp(
          0,
          timer.elapsedMilliseconds,
        );
        await channel.invokeMethod<void>('thumbnailReady', {
          'key': key,
          'path': path,
        });
        unawaited(
          DevLog.write(
            'ThumbLoad',
            'event=cache_write layer=dart queue=write waitMs=$waitMs ioMs=${written.ioMs} bytes=${bytes.length} thread=bg key=${safeCacheLabel(label)}',
          ),
        );
      }
    } on MissingPluginException {
      /* Memory-only non-Android host. */
    }
    unawaited(
      DevLog.write('ThumbCache', 'event=store key=${safeCacheLabel(label)}'),
    );
    return (bytes: bytes, path: path);
  }

  Future<Uint8List> _download(
    MediaRequestPolicy policy,
    MediaRequestResource resource,
    String label,
  ) async {
    unawaited(
      DevLog.write('ThumbCache', 'event=miss key=${safeCacheLabel(label)}'),
    );
    final response = await sendAuthorizedMediaGet(
      client,
      policy,
      resource,
      timeout: const Duration(seconds: 8),
    );
    if (response.statusCode != 200) {
      await response.stream.drain<void>();
      throw const HttpException('THUMBNAIL_HTTP_STATUS');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 8),
    )) {
      if (builder.length + chunk.length > 10 * 1024 * 1024)
        throw const HttpException('THUMBNAIL_TOO_LARGE');
      builder.add(chunk);
    }
    final bytes = builder.takeBytes();
    if (bytes.isEmpty) throw const HttpException('THUMBNAIL_EMPTY');
    if (response.contentLength != null &&
        bytes.length != response.contentLength) {
      throw const HttpException('THUMBNAIL_TRUNCATED');
    }
    return bytes;
  }
}

/// Foreground tasks precede queued speculative work; no synchronous file I/O.
class ThumbnailSlots {
  ThumbnailSlots(this.limit);
  final int limit;
  int _active = 0;
  final _waiting = <Completer<void>>[];
  Future<T> run<T>(
    Future<T> Function() action, {
    String? event,
    String queue = 'read',
    String? key,
  }) async {
    final timer = Stopwatch()..start();
    if (_active >= limit) {
      final ready = Completer<void>();
      _waiting.add(ready);
      await ready.future;
    } else {
      _active++;
    }
    final waitMs = timer.elapsedMilliseconds;
    try {
      return await action();
    } finally {
      if (event != null)
        unawaited(
          DevLog.write(
            'ThumbLoad',
            'event=$event layer=dart queue=$queue waitMs=$waitMs ioMs=${timer.elapsedMilliseconds - waitMs} ms=${timer.elapsedMilliseconds} key=${safeCacheLabel(key ?? 'unbound')}',
          ),
        );
      if (_waiting.isNotEmpty) {
        _waiting.removeAt(0).complete();
      } else {
        _active--;
      }
    }
  }
}

/// Worker owns temporary bytes and publication; channel carries only key/path.
({String path, int ioMs}) writeThumbnailFile(
  ({String root, String key, Uint8List bytes, SendPort origin}) input,
) {
  if (Isolate.current.controlPort == input.origin)
    throw StateError('THUMBNAIL_WRITE_ON_MAIN_ISOLATE');
  final timer = Stopwatch()..start();
  final root = Directory(input.root)..createSync(recursive: true);
  final destination = File('${root.path}/${input.key}');
  final temporary = File(
    '${destination.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
  );
  try {
    temporary.writeAsBytesSync(input.bytes, flush: true);
    validateThumbnailHeader(temporary.readAsBytesSync());
    temporary.setLastModifiedSync(
      DateTime.now().add(const Duration(minutes: 10)),
    );
    temporary.renameSync(destination.path);
    return (path: destination.path, ioMs: timer.elapsedMilliseconds);
  } finally {
    if (temporary.existsSync()) temporary.deleteSync();
  }
}
