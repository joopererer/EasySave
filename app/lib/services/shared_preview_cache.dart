import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

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

/// Dart alone authorizes and downloads images. Native file operations serialize
/// all engines against one 64 MiB directory and return only approved local paths.
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
                ? [item.posterUrl]
                : [...item.fallbacks, item.url];
            for (final url in urls) {
              final resource = resources.where((r) => r.url == url).firstOrNull;
              if (resource == null) continue;
              try {
                await load(
                  policy,
                  resource,
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

  Future<void> _validate(Uint8List bytes) => decodeSlots.run(() async {
    // Some codecs deliberately render partial JPEGs. Reject incomplete
    // containers before asking the codec for dimensions/pixels.
    if (bytes.length >= 2 &&
        bytes[0] == 0xff &&
        bytes[1] == 0xd8 &&
        (bytes.length < 4 ||
            bytes[bytes.length - 2] != 0xff ||
            bytes.last != 0xd9)) {
      throw const FormatException('THUMBNAIL_TRUNCATED_JPEG');
    }
    if (bytes.length >= 8 &&
        bytes[0] == 137 &&
        bytes[1] == 80 &&
        (bytes.length < 20 ||
            ascii.decode(
                  bytes.sublist(bytes.length - 8, bytes.length - 4),
                  allowInvalid: true,
                ) !=
                'IEND')) {
      throw const FormatException('THUMBNAIL_TRUNCATED_PNG');
    }
    if (bytes.length >= 12 &&
        ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
        ByteData.sublistView(bytes).getUint32(4, Endian.little) + 8 !=
            bytes.length) {
      throw const FormatException('THUMBNAIL_TRUNCATED_WEBP');
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width <= 0 || descriptor.height <= 0) {
        throw const FormatException('THUMBNAIL_DIMENSIONS');
      }
      codec = await descriptor.instantiateCodec(
        targetWidth: 1,
        targetHeight: 1,
      );
      final frame = await codec.getNextFrame();
      frame.image.dispose();
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  });

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
  }) async {
    policy.validate(resource);
    final label =
        identity ??
        '${policy.site.id}:unbound:${identityHashCode(resource)}:${resource.role.name}';
    final key = opaquePreviewKey(label);
    final previous = _pending[key];
    if (previous != null) return previous;
    final future = _singleFlight(policy, resource, key, label);
    _pending[key] = future;
    try {
      return await future;
    } finally {
      _pending.remove(key);
    }
  }

  Future<({Uint8List bytes, String? path})> _singleFlight(
    MediaRequestPolicy policy,
    MediaRequestResource resource,
    String key,
    String label,
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
            final cached = await _read(policy, resource, key, label);
            if (cached != null) return cached;
          }
        }
      } on MissingPluginException {
        /* Per-engine fallback for non-Android. */
      }
      for (var attempt = 0; ; attempt++) {
        try {
          return await _load(policy, resource, key, label);
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
    String label,
  ) async {
    final timer = Stopwatch()..start();
    try {
      final path = await channel.invokeMethod<String>('thumbnailRead', {
        'key': key,
      });
      if (path == null) return null;
      final bytes = await File(path).readAsBytes();
      try {
        await _validate(bytes);
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
          'event=cache_read ms=${timer.elapsedMilliseconds} key=${safeCacheLabel(label)}',
        ),
      );
    }
  }

  Future<({Uint8List bytes, String? path})> _load(
    MediaRequestPolicy policy,
    MediaRequestResource resource,
    String key,
    String label,
  ) async {
    final cached = await _read(policy, resource, key, label);
    if (cached != null) return cached;
    return _downloadSlots.run(() => _download(policy, resource, key, label));
  }

  Future<({Uint8List bytes, String? path})> _download(
    MediaRequestPolicy policy,
    MediaRequestResource resource,
    String key,
    String label,
  ) async {
    final timer = Stopwatch()..start();
    await DevLog.write('ThumbCache', 'event=miss key=${safeCacheLabel(label)}');
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
    await _validate(bytes);
    unawaited(
      DevLog.write(
        'ThumbLoad',
        'event=network ms=${timer.elapsedMilliseconds} key=${safeCacheLabel(label)}',
      ),
    );
    policy.validate(resource);
    final expires = DateTime.now().add(const Duration(minutes: 10));
    String? path;
    try {
      path = await channel.invokeMethod<String>('thumbnailWrite', {
        'key': key,
        'bytes': bytes,
        'expires': expires.millisecondsSinceEpoch,
      });
    } on MissingPluginException {
      /* Keep the existing in-memory path on other hosts. */
    }
    await DevLog.write(
      'ThumbCache',
      'event=store key=${safeCacheLabel(label)}',
    );
    return (bytes: bytes, path: path);
  }
}

/// Foreground tasks precede queued speculative work; no synchronous file I/O.
class ThumbnailSlots {
  ThumbnailSlots(this.limit);
  final int limit;
  int _active = 0;
  final _waiting = <Completer<void>>[];
  Future<T> run<T>(Future<T> Function() action) async {
    if (_active >= limit) {
      final ready = Completer<void>();
      _waiting.add(ready);
      await ready.future;
    } else {
      _active++;
    }
    try {
      return await action();
    } finally {
      if (_waiting.isNotEmpty) {
        _waiting.removeAt(0).complete();
      } else {
        _active--;
      }
    }
  }
}
