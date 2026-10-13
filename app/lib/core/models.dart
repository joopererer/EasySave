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
    this.fallbacks = const [],
  });

  final String type;
  final String url;
  final String? videoUrl;
  final num? width;
  final num? height;

  /// Alternate URLs for the same bytes (e.g. the pre-transform original).
  /// Never serialized: toJson must keep matching the spec fixtures exactly.
  final List<String> fallbacks;

  Map<String, Object?> toJson() {
    final map = <String, Object?>{'type': type, 'url': url};
    if (videoUrl != null) map['videoUrl'] = videoUrl;
    if (width != null) map['width'] = width;
    if (height != null) map['height'] = height;
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

/// Mirrors the TS `{ ok, data? , error? }` result shape.
class ParseResult {
  ParseResult.ok(this.data) : ok = true, error = null;
  ParseResult.err(this.error) : ok = false, data = null;

  final bool ok;
  final ParsedPost? data;
  final ParseError? error;
}

class ResolvedVideo {
  ResolvedVideo({required this.url, this.width, this.height});

  final String url;
  final num? width;
  final num? height;
}
