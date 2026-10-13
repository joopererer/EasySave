// Pure-Dart Instagram post parser (no Flutter, only dart:convert).
// Mirrors extension/src/instagram.ts behavior-for-behavior.

import 'dart:convert';

import 'models.dart';

final _shortcodePattern = RegExp(r'/(?:p|reels?|tv)/([A-Za-z0-9-_]+)');
const _shortcodeAlphabet =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
final _dataSjsPattern = RegExp(
  r'<script\b[^>]*\bdata-sjs[^>]*>(\{.+?\})</script>',
  dotAll: true,
);

bool _isRecord(Object? v) => v is Map<String, Object?>;

bool _nonBlank(Object? v) => v is String && v.trim().isNotEmpty;

String _toIsoUtcSeconds(num seconds) {
  final s = DateTime.fromMillisecondsSinceEpoch(
    (seconds * 1000).toInt(),
    isUtc: true,
  ).toIso8601String();
  return s.replaceFirst(RegExp(r'\.\d+Z$'), 'Z');
}

/// Convert an Instagram shortcode to its numeric media id using BigInt
/// (the value exceeds 64-bit float precision). Returns null for empty input
/// or characters outside the alphabet.
String? shortcodeToMediaId(String shortcode) {
  if (shortcode.isEmpty) return null;
  var id = BigInt.zero;
  for (var i = 0; i < shortcode.length; i++) {
    final digit = _shortcodeAlphabet.indexOf(shortcode[i]);
    if (digit < 0) return null;
    id = id * BigInt.from(64) + BigInt.from(digit);
  }
  return id.toString();
}

bool _isProductShaped(Map<String, Object?> obj, String mediaId) {
  final matchesId =
      '${obj['id'] ?? ''}' == mediaId || '${obj['pk'] ?? ''}' == mediaId;
  if (!matchesId) return false;
  return obj.containsKey('video_versions') ||
      obj.containsKey('carousel_media') ||
      obj.containsKey('image_versions2');
}

Map<String, Object?>? _findProduct(Object? root, String mediaId) {
  final seen = Set.identity();
  Map<String, Object?>? visit(Object? node) {
    if (!_isRecord(node) && node is! List) return null;
    if (seen.contains(node)) return null;
    seen.add(node as Object);
    if (_isRecord(node)) {
      final rec = (node as Map).cast<String, Object?>();
      if (_isProductShaped(rec, mediaId)) return rec;
      for (final value in rec.values) {
        final found = visit(value);
        if (found != null) return found;
      }
      return null;
    }
    for (final value in node as List) {
      final found = visit(value);
      if (found != null) return found;
    }
    return null;
  }

  return visit(root);
}

class _Rendition {
  _Rendition({required this.url, required this.width, required this.height});
  final String url;
  final num width;
  final num height;
}

_Rendition? _bestRendition(Object? list) {
  if (list is! List) return null;
  _Rendition? best;
  for (final entry in list) {
    if (entry is! Map<String, Object?>) continue;
    if (!_nonBlank(entry['url'])) continue;
    final width = entry['width'] is num ? entry['width'] as num : 0;
    final height = entry['height'] is num ? entry['height'] as num : 0;
    if (best == null || width * height > best.width * best.height) {
      best = _Rendition(
        url: entry['url'] as String,
        width: width,
        height: height,
      );
    }
  }
  return best;
}

_Rendition? _bestImage(Map<String, Object?> media) {
  final versions = media['image_versions2'];
  final best = _isRecord(versions)
      ? _bestRendition(
          ((versions as Map).cast<String, Object?>())['candidates'],
        )
      : null;
  if (best != null) return best;
  if (_nonBlank(media['display_url'])) {
    return _Rendition(url: media['display_url'] as String, width: 0, height: 0);
  }
  return null;
}

_Rendition? _bestVideoUrl(Map<String, Object?> media) =>
    _bestRendition(media['video_versions']);

MediaItem? _mediaItem(Map<String, Object?> media) {
  final image = _bestImage(media);
  final video = _bestVideoUrl(media);
  if (video != null) {
    final rawDuration = media['video_duration'];
    return MediaItem(
      type: 'video',
      url: image != null ? image.url : video.url,
      videoUrl: image != null ? video.url : null,
      width: video.width,
      height: video.height,
      duration: rawDuration is num ? rawDuration : null,
    );
  }
  if (image != null) {
    return MediaItem(
      type: 'image',
      url: image.url,
      width: image.width,
      height: image.height,
    );
  }
  return null;
}

/// Parse an Instagram post/reel page from its HTML source.
ParseResult parseInstagram(String html, String pageUrl) {
  final shortcodeMatch = _shortcodePattern.firstMatch(pageUrl);
  final shortcode = shortcodeMatch?.group(1);
  final mediaId = shortcode != null ? shortcodeToMediaId(shortcode) : null;

  Map<String, Object?>? product;
  if (mediaId != null) {
    for (final match in _dataSjsPattern.allMatches(html)) {
      Object? parsed;
      try {
        parsed = jsonDecode(match.group(1)!);
      } catch (_) {
        continue;
      }
      product = _findProduct(parsed, mediaId);
      if (product != null) break;
    }
  }

  final head = html.length > 20000 ? html.substring(0, 20000) : html;
  final looksLikeInstagram =
      pageUrl.contains('instagram.com') ||
      pageUrl.contains('instagr.am') ||
      head.contains('instagram.com') ||
      head.contains('instagr.am') ||
      head.contains('data-sjs');
  if (product == null || shortcode == null) {
    if (looksLikeInstagram) {
      return ParseResult.err(
        ParseError(
          code: ParseErrorCode.loginRequired,
          message: 'Instagram returned a login-gated shell without post data.',
        ),
      );
    }
    return ParseResult.err(
      ParseError(
        code: ParseErrorCode.invalidPage,
        message: 'Not an Instagram post page.',
      ),
    );
  }

  return buildPostFromProduct(product, shortcode);
}

/// Build the unified post output from an already-located product object.
ParseResult buildPostFromProduct(
  Map<String, Object?> product,
  String shortcode,
) {
  Object? userObj = product['user'];
  if (!_isRecord(userObj)) userObj = product['owner'];
  final user = _isRecord(userObj)
      ? (userObj as Map).cast<String, Object?>()
      : <String, Object?>{};
  final authorId = user['pk'] ?? user['id'];
  final author = PostAuthor(
    name: _nonBlank(user['username']) ? user['username'] as String : null,
    id: authorId != null && '$authorId'.isNotEmpty ? '$authorId' : null,
  );

  final captionRaw = product['caption'];
  String caption = '';
  if (captionRaw is String) {
    caption = captionRaw;
  } else if (captionRaw is Map<String, Object?> &&
      captionRaw['text'] is String) {
    caption = captionRaw['text'] as String;
  }

  final takenAt = product['taken_at'];
  final publishedAt = takenAt is num && takenAt.isFinite
      ? _toIsoUtcSeconds(takenAt)
      : '';

  final items = <MediaItem>[];
  final carousel = product['carousel_media'];
  if (carousel is List) {
    for (final child in carousel) {
      if (!_isRecord(child)) continue;
      final item = _mediaItem((child as Map).cast<String, Object?>());
      if (item != null) items.add(item);
    }
  } else {
    final item = _mediaItem(product);
    if (item != null) items.add(item);
  }

  if (items.isEmpty) {
    return ParseResult.err(
      ParseError(
        code: ParseErrorCode.loginRequired,
        message: 'Instagram post has no extractable media.',
      ),
    );
  }

  return ParseResult.ok(
    ParsedPost(
      platform: 'instagram',
      id: shortcode,
      url: 'https://www.instagram.com/p/$shortcode/',
      author: author,
      caption: caption,
      items: items,
      publishedAt: publishedAt.isNotEmpty ? publishedAt : null,
    ),
  );
}
