/// Request requirements contain no Cookie values and are separate from backup
/// media JSON. Only the policy may obtain credentials for an actual URL.
enum MediaResourceRole { image, video, motion, poster, fallback }

enum MediaTransport { background, session }

class MediaRequestRequirements {
  MediaRequestRequirements({
    Map<String, String> headers = const {},
    List<String> cookieDomains = const [],
    this.expiresAt,
    required this.transport,
    required this.resumable,
  }) : headers = Map.unmodifiable(headers),
       cookieDomains = List.unmodifiable(cookieDomains);

  final Map<String, String> headers;
  final List<String> cookieDomains;
  final DateTime? expiresAt;
  final MediaTransport transport;
  final bool resumable;

  factory MediaRequestRequirements.fromJson(Map<String, dynamic> value) {
    Never invalid() =>
        throw const FormatException('REQUEST_REQUIREMENTS_INVALID');
    final headers = value['headers'];
    final cookies = value['cookieDomains'];
    if (headers is! Map ||
        headers.entries.any((e) => e.key is! String || e.value is! String) ||
        cookies is! List ||
        cookies.any((e) => e is! String) ||
        value['resumable'] is! bool) {
      invalid();
    }
    final transport = MediaTransport.values
        .where((v) => v.name == value['transport'])
        .firstOrNull;
    if (transport == null) invalid();
    DateTime? expiry;
    if (value['expiresAt'] != null) {
      final raw = value['expiresAt'];
      if (raw is! String || !raw.endsWith('Z')) invalid();
      expiry = DateTime.tryParse(raw);
      if (expiry == null) invalid();
    }
    return MediaRequestRequirements(
      headers: headers.cast<String, String>(),
      cookieDomains: cookies.cast<String>(),
      expiresAt: expiry,
      transport: transport,
      resumable: value['resumable'] as bool,
    );
  }

  /// Never includes cookies; consumers must not persist the authorized request.
  Map<String, Object?> toJson() => {
    'headers': headers,
    'cookieDomains': cookieDomains,
    if (expiresAt != null) 'expiresAt': expiresAt!.toUtc().toIso8601String(),
    'transport': transport.name,
    'resumable': resumable,
  };
}

class MediaRequestResource {
  const MediaRequestResource({
    required this.role,
    required this.url,
    required this.request,
    this.fallbackFor,
  });

  final MediaResourceRole role;
  final MediaResourceRole? fallbackFor;
  final String url;
  final MediaRequestRequirements request;

  factory MediaRequestResource.fromJson(Map<String, dynamic> value) {
    Never invalid() => throw const FormatException('REQUEST_RESOURCE_INVALID');
    final role = MediaResourceRole.values
        .where((r) => r.name == value['role'])
        .firstOrNull;
    final fallbackFor = MediaResourceRole.values
        .where((r) => r.name == value['fallbackFor'])
        .firstOrNull;
    if (role == null ||
        value['url'] is! String ||
        value['request'] is! Map ||
        (role == MediaResourceRole.fallback &&
            (fallbackFor == null ||
                fallbackFor == MediaResourceRole.fallback)) ||
        (role != MediaResourceRole.fallback &&
            value.containsKey('fallbackFor'))) {
      invalid();
    }
    return MediaRequestResource(
      role: role,
      url: value['url'] as String,
      fallbackFor: fallbackFor,
      request: MediaRequestRequirements.fromJson(
        (value['request'] as Map).cast<String, dynamic>(),
      ),
    );
  }

  MediaRequestResource atUrl(String value) => MediaRequestResource(
    role: role,
    url: value,
    request: request,
    fallbackFor: fallbackFor,
  );

  Map<String, Object?> toJson() => {
    'role': role.name,
    'url': url,
    if (fallbackFor != null) 'fallbackFor': fallbackFor!.name,
    'request': request.toJson(),
  };
}
