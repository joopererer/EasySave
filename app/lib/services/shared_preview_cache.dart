import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../core/media_request.dart';
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
  }) : client = client ?? http.Client();
  static final instance = SharedThumbnailCache();
  final http.Client client;
  final MethodChannel channel;
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
    final future = _load(policy, resource, key, label);
    _pending[key] = future;
    try {
      return await future;
    } finally {
      _pending.remove(key);
    }
  }

  Future<({Uint8List bytes, String? path})> _load(
    MediaRequestPolicy policy,
    MediaRequestResource resource,
    String key,
    String label,
  ) async {
    try {
      final path = await channel.invokeMethod<String>('thumbnailRead', {
        'key': key,
      });
      if (path != null) {
        final bytes = await File(path).readAsBytes();
        policy.validate(resource);
        await DevLog.write(
          'ThumbCache',
          'event=hit key=${safeCacheLabel(label)}',
        );
        return (bytes: bytes, path: path);
      }
    } catch (_) {
      /* A concurrent eviction or a non-Android host is a cache miss. */
    }
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
