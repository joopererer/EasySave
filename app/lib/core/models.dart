// Unified parsing models shared by the XHS and Instagram parsers.
// Mirrors extension/src/*.ts; serialized forms match spec/fixtures expected
// JSON exactly (absent optional fields are omitted, like TS `undefined`).

/// Error codes from the spec error model.
abstract final class ParseErrorCode {
  static const loginRequired = 'LOGIN_REQUIRED';
  static const privateOrUnavailable = 'PRIVATE_OR_UNAVAILABLE';
  static const blocked = 'BLOCKED';
  static const invalidPage = 'INVALID_PAGE';
  static const unsupportedUrl = 'UNSUPPORTED_URL';
  static const timeout = 'TIMEOUT';
}

class PostAuthor {
  PostAuthor({this.name, this.id});

  final String? name;
  final String? id;

  Map<String, Object?> toJson() {
    final map = <String, Object?>{};
    if (name != null) map['name'] = name;
    if (id != null) map['id'] = id;
    return map;
  }
}

class MediaItem {
  MediaItem({
    required this.type,
    required this.url,
    this.videoUrl,
    this.width,
    this.height,
    this.duration,
    this.fallbacks = const [],
  });

  final String type;
  final String url;
  final String? videoUrl;
  final num? width;
  final num? height;

  /// Video length in seconds, from `video.capa.duration` (XHS) or
  /// `video_duration` (IG). Absent when the source provides none; the UI
  /// then shows a bare play badge.
  final num? duration;

  /// Alternate URLs for the same bytes (e.g. the pre-transform original).
  /// Never serialized: toJson must keep matching the spec fixtures exactly.
  final List<String> fallbacks;

  Map<String, Object?> toJson() {
    final map = <String, Object?>{'type': type, 'url': url};
    if (videoUrl != null) map['videoUrl'] = videoUrl;
    if (width != null) map['width'] = width;
    if (height != null) map['height'] = height;
    if (duration != null) map['duration'] = duration;
    return map;
  }
}

/// Unified output: { platform, id, url, author, title?, caption?,
/// publishedAt?, items }.
class ParsedPost {
  ParsedPost({
    required this.platform,
    required this.id,
    required this.url,
    required this.author,
    required this.items,
    this.title,
    this.caption,
    this.publishedAt,
  });

  final String platform;
  final String id;
  final String url;
  final PostAuthor author;
  final List<MediaItem> items;
  final String? title;
  final String? caption;
  final String? publishedAt;

  Map<String, Object?> toJson() {
    final map = <String, Object?>{
      'platform': platform,
      'id': id,
      'url': url,
      'author': author.toJson(),
    };
    if (title != null) map['title'] = title;
    if (caption != null) map['caption'] = caption;
    if (publishedAt != null) map['publishedAt'] = publishedAt;
    map['items'] = [for (final item in items) item.toJson()];
    return map;
  }
}

class ParseError {
  ParseError({required this.code, required this.message});

  final String code;
  final String message;

  Map<String, Object?> toJson() => {'code': code, 'message': message};
}

class ResolvedVideo {
  ResolvedVideo({required this.url, this.width, this.height});

  final String url;
  final num? width;
  final num? height;
}

/// Mirrors the TS `{ ok, data? , error? }` result shape. `rawImages`
/// carries the untouched image entries for diagnostics only.
class ParseResult {
  ParseResult.ok(this.data, [List<RawImageEntry>? rawImages])
    : ok = true,
      error = null,
      rawImages = rawImages ?? const [];
  ParseResult.err(this.error) : ok = false, data = null, rawImages = const [];

  final bool ok;
  final ParsedPost? data;
  final ParseError? error;
  final List<RawImageEntry> rawImages;
}

/// One raw image entry per note image, for diagnostics: the entry's own
/// keys plus every infoList rendition (scene + URL), so a "still
/// watermarked" report shows exactly what the server offered.
/// Never serialized into ParsedPost; only the diagnostics button reads it.
class RawImageEntry {
  RawImageEntry({required this.keys, required this.scenes});

  final List<String> keys;
  final List<RawScene> scenes;
}

class RawScene {
  RawScene({required this.scene, required this.url});

  final String scene;
  final String url;
}
