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

  factory PostAuthor.fromJson(Map<String, dynamic> json) => PostAuthor(
    name: json['name'] as String?,
    id: json['id'] as String?,
  );

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
    this.isGif,
    this.videoUrl,
    this.posterUrl,
    this.width,
    this.height,
    this.duration,
    this.fallbacks = const [],
  });

  factory MediaItem.fromJson(Map<String, dynamic> json) => MediaItem(
    type: json['type'] as String? ?? 'image',
    url: json['url'] as String? ?? '',
    isGif: json['isGif'] as bool?,
    videoUrl: json['videoUrl'] as String?,
    posterUrl: json['posterUrl'] as String?,
    width: json['width'] as num?,
    height: json['height'] as num?,
    duration: json['duration'] as num?,
    fallbacks:
        (json['fallbacks'] as List?)?.whereType<String>().toList() ??
        const [],
  );

  final String type;
  final String url;
  final bool? isGif;
  final String? videoUrl;

  /// Still-image cover for a video item (XHS `imageList[0]`). IG video
  /// items already carry the preview in `url`, so this stays null there.
  final String? posterUrl;
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
    final map = <String, Object?>{'type': type};
    if (isGif == true) map['isGif'] = true;
    map['url'] = url;
    if (videoUrl != null) map['videoUrl'] = videoUrl;
    if (posterUrl != null) map['posterUrl'] = posterUrl;
    if (width != null) map['width'] = width;
    if (height != null) map['height'] = height;
    if (duration != null) map['duration'] = duration;
    // Fallbacks must survive the history round-trip: posts reopened from
    // history rebuild their items from this JSON, and without the backup
    // URLs a single slow CDN host hangs every cell.
    if (fallbacks.isNotEmpty) map['fallbacks'] = fallbacks;
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

  factory ParsedPost.fromJson(Map<String, dynamic> json) => ParsedPost(
    platform: json['platform'] as String,
    id: json['id'] as String,
    url: json['url'] as String,
    author: json['author'] is Map
        ? PostAuthor.fromJson((json['author'] as Map).cast<String, dynamic>())
        : PostAuthor(),
    items: [
      if (json['items'] is List)
        for (final item in json['items'] as List)
          if (item is Map)
            MediaItem.fromJson(item.cast<String, dynamic>()),
    ],
    title: json['title'] as String?,
    caption: json['caption'] as String?,
    publishedAt: json['publishedAt'] as String?,
  );

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

  factory ParseError.fromJson(Map<String, dynamic> json) => ParseError(
    code: json['code'] as String? ?? ParseErrorCode.invalidPage,
    message: json['message'] as String? ?? '解析失败',
  );

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

  factory ParseResult.fromJson(Map<String, dynamic> json) {
    final ok = json['ok'] == true;
    if (ok) {
      final data = json['data'] is Map
          ? ParsedPost.fromJson((json['data'] as Map).cast<String, dynamic>())
          : null;
      return ParseResult.ok(data);
    } else {
      final error = json['error'] is Map
          ? ParseError.fromJson((json['error'] as Map).cast<String, dynamic>())
          : ParseError(code: ParseErrorCode.invalidPage, message: '解析失败');
      return ParseResult.err(error);
    }
  }

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
