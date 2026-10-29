import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../core/dev_log.dart';
import '../core/media_request.dart';
import '../core/models.dart';
import 'site_registry.dart';

typedef MediaCookieReader = Future<String> Function(Uri actualMediaUrl);
typedef MediaPolicyRejectionLogger = void Function(String code, String host);

/// Only a fixed code and validated hostname may leave a rejection.
class MediaPolicyException implements Exception {
  const MediaPolicyException(this.code, this.host);
  final String code;
  final String host;
  @override
  String toString() => '$code host=$host';
}

/// Ephemeral authorization. No JSON, persistence, or credential-bearing toString.
class AuthorizedMediaRequest {
  AuthorizedMediaRequest._(
    this._policy,
    this.resource,
    this.uri,
    this.headers,
    this.cookie,
  );
  final MediaRequestPolicy _policy;
  final MediaRequestResource resource;
  final Uri uri;
  final Map<String, String> headers;
  final String? cookie;
  Map<String, String> get wireHeaders => {
    ...headers,
    if (cookie != null && cookie!.isNotEmpty) 'Cookie': cookie!,
  };
  @override
  String toString() => 'AuthorizedMediaRequest host=${uri.host}';
}

class MediaRequestPolicy {
  MediaRequestPolicy(
    this.site, {
    MediaCookieReader? readCookie,
    DateTime Function()? now,
    MediaPolicyRejectionLogger? logRejection,
  }) : _readCookie = readCookie ?? _systemCookie,
       _now = now ?? DateTime.now,
       _logRejection = logRejection ?? _log;

  final SiteDefinition site;
  final MediaCookieReader _readCookie;
  final DateTime Function() _now;
  final MediaPolicyRejectionLogger _logRejection;
  static final _controls = RegExp(r'[\r\n\x00]');
  // Uri canonicalizes an empty userinfo marker away, so inspect raw authority.
  static final _userinfo = RegExp(r'^(?:[A-Za-z][A-Za-z0-9+.-]*:)?//[^/?#]*@');
  static final _domain = RegExp(
    r'^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]*$',
  );
  static const _headerNames = {
    'referer': 'Referer',
    'origin': 'Origin',
    'user-agent': 'User-Agent',
    'range': 'Range',
  };

  static void _log(String code, String host) {
    unawaited(DevLog.write('RequestPolicy', '$code host=$host'));
  }

  static Future<String> _systemCookie(Uri actualMediaUrl) async {
    final cookies = await CookieManager.instance().getCookies(
      url: WebUri(actualMediaUrl.toString()),
    );
    // CookieManager performs URL/path/secure matching. Never query a homepage.
    if (cookies.any(
      (c) =>
          !RegExp(r"^[!#$%&'*+\-.^_\x60$|~0-9A-Za-z]+$").hasMatch(c.name) ||
          _controls.hasMatch(c.value.toString()),
    )) {
      throw const FormatException('REQUEST_COOKIE_INVALID');
    }
    return cookies.map((c) => '${c.name}=${c.value}').join('; ');
  }

  String _host(String raw) {
    final host = Uri.tryParse(raw)?.host.toLowerCase() ?? '';
    return RegExp(r'^[a-z0-9.:\[\]-]{1,253}$').hasMatch(host) ? host : '';
  }

  Never _reject(String code, String raw) {
    final host = _host(raw);
    _logRejection(code, host);
    throw MediaPolicyException(code, host);
  }

  Never rejectRedirect(Uri uri) =>
      _reject('REQUEST_REDIRECT_REJECTED', uri.toString());

  Never rejectResource(String url) =>
      _reject('REQUEST_RESOURCE_MISMATCH', url);

  Map<String, String> _headers(Map source, String url) {
    final result = <String, String>{};
    for (final entry in source.entries) {
      final key = entry.key is String
          ? _headerNames[(entry.key as String).toLowerCase()]
          : null;
      if (key == null ||
          entry.value is! String ||
          _controls.hasMatch(entry.value as String) ||
          result.containsKey(key)) {
        _reject('REQUEST_HEADER_REJECTED', url);
      }
      result[key] = entry.value as String;
    }
    return result;
  }

  /// Validate every candidate, including ones that have not yet been attempted.
  /// No cookies are read here, so callers can validate a complete resource set.
  Uri validate(MediaRequestResource resource) {
    final raw = resource.url;
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        uri.scheme != 'https' ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        _userinfo.hasMatch(raw) ||
        _controls.hasMatch(raw)) {
      _reject('REQUEST_URL_REJECTED', raw);
    }
    final config = site.data['download'] as Map;
    final hosts = (config['mediaHosts'] as List).cast<Map>();
    if (!_domain.hasMatch(uri.host) ||
        !hosts.any((h) => matchesHost(uri.host, h))) {
      _reject('REQUEST_HOST_REJECTED', raw);
    }
    _headers(config['headers'] as Map, raw);
    _headers(resource.request.headers, raw);
    final declared = (config['cookieDomains'] as List).cast<String>().toSet();
    for (final domain in resource.request.cookieDomains) {
      if (!_domain.hasMatch(domain) || !declared.contains(domain)) {
        _reject('REQUEST_COOKIE_DOMAIN_REJECTED', raw);
      }
    }
    if (resource.request.expiresAt != null &&
        !resource.request.expiresAt!.isAfter(_now())) {
      _reject('REQUEST_EXPIRED', raw);
    }
    return uri;
  }

  Future<AuthorizedMediaRequest> authorize(
    MediaRequestResource resource,
  ) async {
    final uri = validate(resource);
    final config = site.data['download'] as Map;
    final headers = {
      ..._headers(config['headers'] as Map, resource.url),
      ..._headers(resource.request.headers, resource.url),
    };
    final eligible = resource.request.cookieDomains.any(
      (d) => uri.host == d || uri.host.endsWith('.$d'),
    );
    String? cookie;
    if (eligible) {
      try {
        cookie = await _readCookie(uri);
      } catch (_) {
        _reject('REQUEST_COOKIE_READ_FAILED', resource.url);
      }
      if (_controls.hasMatch(cookie)) {
        _reject('REQUEST_COOKIE_REJECTED', resource.url);
      }
      // Expiry can elapse while querying the platform CookieManager.
      validate(resource);
    }
    return AuthorizedMediaRequest._(
      this,
      resource,
      uri,
      Map.unmodifiable(headers),
      cookie,
    );
  }

  /// Consumers must disable automatic redirects and call this for EVERY hop.
  /// The old cookie is never an input to the next authorization.
  Future<AuthorizedMediaRequest> redirect(
    AuthorizedMediaRequest previous,
    String location,
  ) {
    if (!identical(previous._policy, this)) {
      _reject('REQUEST_REDIRECT_REJECTED', previous.resource.url);
    }
    if (_userinfo.hasMatch(location)) {
      _reject('REQUEST_URL_REJECTED', location);
    }
    Uri next;
    try {
      if (_controls.hasMatch(location)) throw const FormatException();
      next = previous.uri.resolve(location);
    } catch (_) {
      _reject('REQUEST_REDIRECT_REJECTED', previous.resource.url);
    }
    return authorize(previous.resource.atUrl(next.toString()));
  }

  /// Use with legacy or v2 parser results; every fallback must also be checked.
  List<MediaRequestResource> resourcesFor(MediaItem item) {
    final config = site.data['download'] as Map;
    final slots = <(MediaResourceRole, String, MediaResourceRole?)>[];
    final video = item.type == 'video';
    final primary = video
        ? (item.videoUrl != null && item.videoUrl != item.url
              ? MediaResourceRole.poster
              : MediaResourceRole.video)
        : MediaResourceRole.image;
    slots.add((primary, item.url, null));
    if (item.videoUrl != null && (!video || item.videoUrl != item.url)) {
      slots.add((
        video ? MediaResourceRole.video : MediaResourceRole.motion,
        item.videoUrl!,
        null,
      ));
    }
    if (item.posterUrl != null) {
      slots.add((MediaResourceRole.poster, item.posterUrl!, null));
    }
    for (final url in item.fallbacks) {
      slots.add((MediaResourceRole.fallback, url, primary));
    }
    final explicit = item.requestResources;
    if (explicit != null &&
        (explicit.length != slots.length ||
            List.generate(slots.length, (i) => i).any(
              (i) =>
                  explicit[i].role != slots[i].$1 ||
                  explicit[i].url != slots[i].$2 ||
                  explicit[i].fallbackFor != slots[i].$3,
            ))) {
      _reject('REQUEST_RESOURCE_MISMATCH', item.url);
    }
    final result =
        explicit ??
        [
          for (final slot in slots)
            MediaRequestResource(
              role: slot.$1,
              url: slot.$2,
              fallbackFor: slot.$3,
              request: _legacyRequirements(config, slot.$3 ?? slot.$1),
            ),
        ];
    for (final resource in result) {
      validate(resource);
    }
    return List.unmodifiable(result);
  }

  MediaRequestRequirements _legacyRequirements(
    Map config,
    MediaResourceRole role,
  ) {
    final override =
        (config['resourceDefaults'] as Map?)?[role.name] as Map? ?? {};
    return MediaRequestRequirements.fromJson({
      'headers': {
        ...config['headers'] as Map,
        ...override['headers'] as Map? ?? {},
      },
      'cookieDomains': override['cookieDomains'] ?? config['cookieDomains'],
      'transport': override['transport'] ?? config['transport'],
      'resumable': override['resumable'] ?? config['resumable'],
    });
  }
}
