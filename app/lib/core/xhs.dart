// Pure-Dart Xiaohongshu note parser (no Flutter, only dart:convert).
// Mirrors extension/src/xhs.ts behavior-for-behavior; see spec/parsing.md.

import 'dart:convert';

import 'models.dart';

final _noteIdPattern = RegExp(
  r'/(?:explore|discovery\/item|user\/profile\/[^/]+)/([a-f0-9]{24})',
  caseSensitive: false,
);
const _stateMarkers = ['__INITIAL_STATE__', '__NEXT_DATA__', '__NUXT__'];
final _hex32 = RegExp(r'^[a-fA-F0-9]{32}$');
const _undefinedWord = 'undefined';

bool _isRecord(Object? v) => v is Map<String, Object?>;

bool _nonBlank(Object? v) => v is String && v.trim().isNotEmpty;

String? _pickString(Map<String, Object?> obj, List<String> keys) {
  for (final key in keys) {
    final v = obj[key];
    if (_nonBlank(v)) return v as String;
  }
  return null;
}

String _toIsoUtc(int ms) {
  final s = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toIso8601String();
  return s.replaceFirst(RegExp(r'\.\d+Z$'), 'Z');
}

String toHttps(String url) {
  return url.startsWith('http://') ? 'https://${url.substring('http://'.length)}' : url;
}

/// Rewrite an XHS CDN image URL to its canonical original form.
String transformImageUrl(String url) {
  final https = toHttps(url);
  final parsed = Uri.tryParse(https);
  if (parsed == null || !parsed.hasAuthority) return https;
  final host = parsed.host.toLowerCase();
  if (!host.endsWith('.xhscdn.com') && !host.endsWith('.xiaohongshu.com')) return https;
  final withoutStyle = parsed.path.split('!').first;
  final parts = withoutStyle.split('/').where((p) => p.isNotEmpty).toList();
  final token = parts.length > 2 && _hex32.hasMatch(parts[1])
      ? parts.sublist(2).join('/')
      : parts.join('/');
  if (token.isEmpty) return https;
  return 'https://ci.xiaohongshu.com/$token';
}

class _Scan {
  _Scan(this.start, this.end);
  final int start;
  final int end;
}

/// Scan a balanced `{...}` object starting at the first `{` at/after [from].
_Scan? _scanBalancedObject(String html, int from) {
  final start = html.indexOf('{', from);
  if (start < 0) return null;
  var depth = 0;
  var inString = false;
  var escaped = false;
  for (var i = start; i < html.length; i++) {
    final c = html[i];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (c == '\\') {
        escaped = true;
      } else if (c == '"') {
        inString = false;
      }
    } else if (c == '"') {
      inString = true;
    } else if (c == '{') {
      depth++;
    } else if (c == '}') {
      depth--;
      if (depth == 0) return _Scan(start, i);
    }
  }
  return null;
}

bool _isIdChar(String c) {
  final u = c.codeUnitAt(0);
  return (u >= 65 && u <= 90) ||
      (u >= 97 && u <= 122) ||
      (u >= 48 && u <= 57) ||
      c == '_' ||
      c == r'$';
}

/// Replace JS `undefined` literals outside string literals with `null`.
/// Text inside strings (including the word "undefined") is untouched.
String sanitizeJsUndefined(String source) {
  final out = StringBuffer();
  var i = 0;
  var inString = false;
  var escaped = false;
  while (i < source.length) {
    final c = source[i];
    if (inString) {
      out.write(c);
      if (escaped) {
        escaped = false;
      } else if (c == '\\') {
        escaped = true;
      } else if (c == '"') {
        inString = false;
      }
      i++;
      continue;
    }
    if (c == '"') {
      inString = true;
      out.write(c);
      i++;
      continue;
    }
    if (source.startsWith(_undefinedWord, i) &&
        (i == 0 || !_isIdChar(source[i - 1])) &&
        (i + _undefinedWord.length >= source.length ||
            !_isIdChar(source[i + _undefinedWord.length]))) {
      out.write('null');
      i += _undefinedWord.length;
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

Object? _tryParseJson(String text) {
  try {
    return jsonDecode(text);
  } catch (_) {
    return null;
  }
}

Object? _extractJsonAfter(String html, String marker) {
  var from = 0;
  for (;;) {
    final at = html.indexOf(marker, from);
    if (at < 0) return null;
    final scanned = _scanBalancedObject(html, at + marker.length);
    if (scanned == null) return null;
    final raw = html.substring(scanned.start, scanned.end + 1);
    final parsed = _tryParseJson(raw) ?? _tryParseJson(sanitizeJsUndefined(raw));
    if (parsed != null) return parsed;
    from = scanned.end + 1;
  }
}

Map<String, Object?>? _extractNoteDetailEntry(String html, String? wantedId) {
  var from = 0;
  for (;;) {
    final at = html.indexOf('"noteDetailMap"', from);
    if (at < 0) return null;
    final colon = html.indexOf(':', at + '"noteDetailMap"'.length);
    if (colon < 0) return null;
    final scanned = _scanBalancedObject(html, colon + 1);
    if (scanned == null) return null;
    final raw = html.substring(scanned.start, scanned.end + 1);
    final map = _tryParseJson(raw) ?? _tryParseJson(sanitizeJsUndefined(raw));
    if (_isRecord(map)) {
      final m = (map as Map).cast<String, Object?>();
      if (wantedId != null && _isRecord(m[wantedId])) {
        final entry = (m[wantedId] as Map).cast<String, Object?>();
        final inner = entry['note'];
        return _isRecord(inner) ? (inner as Map).cast<String, Object?>() : entry;
      }
      if (wantedId == null) {
        for (final entry in m.values) {
          if (!_isRecord(entry)) continue;
          final e = (entry as Map).cast<String, Object?>();
          final inner = e['note'];
          final note = _isRecord(inner) ? (inner as Map).cast<String, Object?>() : e;
          if (_isNoteShaped(note)) return note;
        }
      }
    }
    from = scanned.end + 1;
  }
}

bool _isNoteShaped(Map<String, Object?> obj) {
  if (_nonBlank(obj['noteId'])) {
    if (_nonBlank(obj['title']) ||
        _nonBlank(obj['desc']) ||
        _nonBlank(obj['description']) ||
        obj['imageList'] is List ||
        obj['images'] is List ||
        _isRecord(obj['video'])) {
      return true;
    }
  }
  final list = obj['imageList'] ?? obj['images'];
  if (list is List && list.isNotEmpty) {
    final first = list[0];
    if (_isRecord(first)) {
      final f = (first as Map).cast<String, Object?>();
      if (f.containsKey('urlDefault') ||
          f.containsKey('url') ||
          f.containsKey('traceId') ||
          f.containsKey('infoList')) {
        return true;
      }
    }
  }
  final video = obj['video'];
  if (_isRecord(video)) {
    final v = (video as Map).cast<String, Object?>();
    if (v.containsKey('consumer') ||
        v.containsKey('media') ||
        v.containsKey('mediaV2') ||
        v.containsKey('stream') ||
        v.containsKey('originVideoKey')) {
      return true;
    }
  }
  return false;
}

class _FoundNote {
  _FoundNote(this.note);
  final Map<String, Object?> note;
}

Map<String, Object?>? _deepFindNote(Object? root, String? wantedId) {
  final seen = Set.identity();
  Map<String, Object?>? fallback;
  void visit(Object? node, int depth) {
    if (!_isRecord(node) && node is! List) return;
    if (seen.contains(node) || depth > 24) return;
    seen.add(node as Object);
    if (_isRecord(node)) {
      final rec = (node as Map).cast<String, Object?>();
      if (_nonBlank(rec['noteId']) && rec['noteId'] == wantedId) {
        throw _FoundNote(rec);
      }
      if (fallback == null && wantedId == null && _isNoteShaped(rec)) fallback = rec;
      for (final value in rec.values) {
        visit(value, depth + 1);
      }
    } else {
      for (final value in node as List) {
        visit(value, depth + 1);
      }
    }
  }

  try {
    visit(root, 0);
  } on _FoundNote catch (e) {
    return e.note;
  }
  return fallback;
}

class _VideoCandidate {
  _VideoCandidate({required this.url, required this.watermarked, required this.width, required this.height});
  final String url;
  final bool watermarked;
  final num width;
  final num height;
}

List<Map<String, Object?>> _streamEntries(Object? stream) {
  if (!_isRecord(stream)) return [];
  final out = <Map<String, Object?>>[];
  for (final arr in ((stream as Map).cast<String, Object?>()).values) {
    if (arr is List) {
      for (final entry in arr) {
        if (_isRecord(entry)) out.add((entry as Map).cast<String, Object?>());
      }
    }
  }
  return out;
}

_VideoCandidate? _candidateFromEntry(Map<String, Object?> entry) {
  final type = entry['streamType'] ?? entry['stream_type'];
  final desc = entry['streamDesc'] ?? entry['stream_desc'];
  final watermarked = type == 259 ||
      type == 309 ||
      (desc is String && desc.toUpperCase() == 'WEB_LIVEPHOTO_19');
  final backups = entry['backupUrls'] is List
      ? entry['backupUrls'] as List
      : entry['backup_urls'] is List
          ? entry['backup_urls'] as List
          : const [];
  final urls = [
    entry['masterUrl'],
    entry['master_url'],
    ...backups,
    entry['url'],
  ].where(_nonBlank).cast<String>().toList();
  if (urls.isEmpty) return null;
  final width = entry['width'] is num ? entry['width'] as num : 0;
  final height = entry['height'] is num ? entry['height'] as num : 0;
  return _VideoCandidate(url: toHttps(urls[0]), watermarked: watermarked, width: width, height: height);
}

List<_VideoCandidate> _collectStreamCandidates(Object? container) {
  if (!_isRecord(container)) return [];
  final rec = (container as Map).cast<String, Object?>();
  final streamObj = rec.containsKey('stream') && _isRecord(rec) ? rec['stream'] : container;
  return [
    for (final e in _streamEntries(streamObj))
      _candidateFromEntry(e),
  ].whereType<_VideoCandidate>().toList();
}

/// Resolve the original video file: supplied originVideoKey wins, else the
/// best non-watermarked stream rendition.
ResolvedVideo? resolveVideoUrl(Object? video) {
  if (!_isRecord(video)) return null;
  final rec = (video as Map).cast<String, Object?>();
  final consumer = rec['consumer'];
  final key = (_isRecord(consumer)
          ? _pickString((consumer as Map).cast<String, Object?>(), const ['originVideoKey'])
          : null) ??
      _pickString(rec, const ['originVideoKey']);
  if (key != null) {
    if (RegExp(r'^https?://', caseSensitive: false).hasMatch(key)) {
      return ResolvedVideo(url: toHttps(key));
    }
    return ResolvedVideo(url: 'https://sns-video-bd.xhscdn.com/${key.replaceFirst(RegExp(r'^/+'), '')}');
  }
  final candidates = <_VideoCandidate>[];
  final media = rec['media'];
  if (_isRecord(media)) {
    final m = (media as Map).cast<String, Object?>();
    if (m.containsKey('stream')) candidates.addAll(_collectStreamCandidates(m['stream']));
  }
  if (rec.containsKey('stream')) candidates.addAll(_collectStreamCandidates(rec['stream']));
  if (rec['mediaV2'] is String) {
    try {
      final parsed = jsonDecode(rec['mediaV2'] as String);
      if (_isRecord(parsed)) {
        final p = (parsed as Map).cast<String, Object?>();
        if (p.containsKey('stream')) candidates.addAll(_collectStreamCandidates(p['stream']));
      }
    } catch (_) {
      // Ignore unparseable app-media payloads; other buckets may still apply.
    }
  }
  final best = _bestVideo(candidates);
  if (best == null) return null;
  return ResolvedVideo(
    url: best.url,
    width: best.width > 0 ? best.width : null,
    height: best.height > 0 ? best.height : null,
  );
}

_VideoCandidate? _bestVideo(List<_VideoCandidate> candidates) {
  if (candidates.isEmpty) return null;
  final sorted = List.of(candidates)
    ..sort((a, b) {
      if (a.watermarked != b.watermarked) return a.watermarked ? 1 : -1;
      return (b.width * b.height).compareTo(a.width * a.height);
    });
  return sorted[0];
}

/// Primary URL plus alternates serving the same bytes.
class _ImageRef {
  _ImageRef(this.url, [List<String>? fallbacks])
      : fallbacks = fallbacks ?? const [];
  final String url;
  final List<String> fallbacks;
}

/// Pick the watermark-free scene rendition: WB_DFT entries come in versions
/// with and without watermark, distinguished by the trailing scene token
/// (`wb_dft` clean vs `watermark`/`wm` watermarked); WB_PRV renditions are
/// small previews. Returns null when nothing in the list has a URL.
String? _sceneUrl(List<Object?> info, {required bool watermarked}) {
  String? anyClean;
  for (final e in info) {
    if (e is! Map<String, Object?>) continue;
    final u = _pickString(e, const ['url']);
    if (u == null) continue;
    final scene = (e['imageScene'] as String?) ?? '';
    if (scene != 'WB_DFT' && scene != 'WB_PRV' && scene.isNotEmpty) continue;
    if (_looksWatermarked(u)) {
      if (watermarked) return transformImageUrl(u);
      continue;
    }
    if (scene == 'WB_DFT') return transformImageUrl(u);
    anyClean ??= transformImageUrl(u);
  }
  if (watermarked) return null;
  return anyClean;
}

/// Filenames containing `watermark` (or `wm` tokens) are server-watermarked
/// renditions; the bare `wb_dft` file is the clean original.
bool _looksWatermarked(String url) {
  final file = url.split('/').last.toLowerCase();
  if (file.contains('watermark')) return true;
  return RegExp(r'(^|[^a-z])wm([^a-z]|$)').hasMatch(file);
}

_ImageRef? _imageUrlOf(Map<String, Object?> entry) {
  final direct = _pickString(entry, const ['urlDefault', 'url']);
  if (direct != null) {
    final primary = transformImageUrl(direct);
    final raw = toHttps(direct);
    return _ImageRef(primary, raw == primary ? const [] : [raw]);
  }
  // Entries without a direct URL still carry renditions in infoList
  // (prefer the clean default scene) or at least a fileId.
  final info = entry['infoList'];
  if (info is List) {
    final clean = _sceneUrl(info.cast<Object?>(), watermarked: false);
    final marked = _sceneUrl(info.cast<Object?>(), watermarked: true);
    if (clean != null) {
      return _ImageRef(clean, marked != null ? [marked] : const []);
    }
    if (marked != null) return _ImageRef(marked);
  }
  final fileId = _pickString(entry, const ['fileId']);
  if (fileId != null) {
    final token = fileId.split('!').first;
    if (token.isNotEmpty) return _ImageRef('https://ci.xiaohongshu.com/$token');
  }
  final traceId = _pickString(entry, const ['traceId']);
  if (traceId != null) return _ImageRef('https://sns-img-qc.xhscdn.com/$traceId');
  return null;
}

int? _asInt(Object? v) {
  if (v is int) return v;
  if (v is double && v.isFinite && v == v.roundToDouble()) return v.toInt();
  return null;
}

/// Locate the wanted note inside already-parsed embedded states.
/// Entry point for WebView callers passing `__INITIAL_STATE__` JSON directly.
Map<String, Object?>? findNoteInStates(List<Object?> states, String? wantedId) {
  for (final state in states) {
    if (!_isRecord(state)) continue;
    final s = (state as Map).cast<String, Object?>();
    Object? byMap;
    final noteObj = s['note'];
    if (_isRecord(noteObj)) {
      final inner = (noteObj as Map).cast<String, Object?>();
      final map = inner['noteDetailMap'];
      if (_isRecord(map)) byMap = ((map as Map).cast<String, Object?>())[wantedId ?? ''];
    }
    Map<String, Object?>? fromMap;
    if (_isRecord(byMap)) {
      final e = (byMap as Map).cast<String, Object?>();
      final inner = e['note'];
      fromMap = _isRecord(inner) ? (inner as Map).cast<String, Object?>() : e;
    }
    if (fromMap != null &&
        (wantedId == null || !_nonBlank(fromMap['noteId']) || fromMap['noteId'] == wantedId)) {
      return fromMap;
    }
    Object? mobile;
    final noteData = s['noteData'];
    if (_isRecord(noteData)) {
      final nd = (noteData as Map).cast<String, Object?>();
      final data = nd['data'];
      if (_isRecord(data)) mobile = ((data as Map).cast<String, Object?>())['noteData'];
    }
    Map<String, Object?>? mobileNote;
    if (_isRecord(mobile)) {
      final m = (mobile as Map).cast<String, Object?>();
      final inner = m['note'];
      mobileNote = _isRecord(inner) ? (inner as Map).cast<String, Object?>() : m;
    }
    if (mobileNote != null &&
        (wantedId == null ||
            !_nonBlank(mobileNote['noteId']) ||
            mobileNote['noteId'] == wantedId)) {
      return mobileNote;
    }
  }
  for (final state in states) {
    final note = _deepFindNote(state, wantedId);
    if (note != null &&
        (wantedId == null || !_nonBlank(note['noteId']) || note['noteId'] == wantedId)) {
      return note;
    }
  }
  return null;
}

ParseResult _completeXhs(Map<String, Object?>? note, String? wantedId, bool looksLikeXhs) {
  if (note == null) {
    if (looksLikeXhs) {
      return ParseResult.err(ParseError(
        code: ParseErrorCode.loginRequired,
        message: 'Xiaohongshu returned an authenticated-only shell without note data.',
      ));
    }
    return ParseResult.err(ParseError(
      code: ParseErrorCode.invalidPage,
      message: 'Not a Xiaohongshu note page.',
    ));
  }
  final rawId = note['noteId'];
  final noteId = _nonBlank(rawId) ? rawId as String : (wantedId ?? '');
  if (noteId.isEmpty) {
    return ParseResult.err(ParseError(
      code: ParseErrorCode.invalidPage,
      message: 'Could not determine the note id.',
    ));
  }
  return buildNoteFromRecord(note, noteId);
}

/// Parse a Xiaohongshu note page from its HTML source.
ParseResult parseXhs(String html, String pageUrl) {
  final idMatch = _noteIdPattern.firstMatch(pageUrl);
  final wantedId = idMatch?.group(1)?.toLowerCase();

  final states = <Object?>[];
  for (final marker in _stateMarkers) {
    final parsed = _extractJsonAfter(html, marker);
    if (parsed != null) states.add(parsed);
  }

  Map<String, Object?>? note =
      findNoteInStates(states, wantedId) ?? _extractNoteDetailEntry(html, wantedId);
  final foundId = note?['noteId'];
  if (note != null && wantedId != null && _nonBlank(foundId) && (foundId as String).toLowerCase() != wantedId) {
    // A mismatched id means stale data from another post: never present it
    // as the requested note.
    note = null;
  }

  final head = html.length > 20000 ? html.substring(0, 20000) : html;
  final looksLikeXhs =
      pageUrl.contains('xiaohongshu.com') || pageUrl.contains('xhslink') || head.contains('xiaohongshu.com') || head.contains('xhslink') || head.contains('__INITIAL_STATE__');
  return _completeXhs(note, wantedId, looksLikeXhs);
}

/// Parse a Xiaohongshu note from decoded `__INITIAL_STATE__` JSON
/// (e.g. read by a WebView), without HTML.
ParseResult parseXhsState(Object? state, String pageUrl) {
  final idMatch = _noteIdPattern.firstMatch(pageUrl);
  final wantedId = idMatch?.group(1)?.toLowerCase();
  Map<String, Object?>? note = findNoteInStates([state], wantedId);
  final foundId = note?['noteId'];
  if (note != null && wantedId != null && _nonBlank(foundId) && (foundId as String).toLowerCase() != wantedId) {
    note = null;
  }
  final looksLikeXhs = pageUrl.contains('xiaohongshu.com') || pageUrl.contains('xhslink');
  return _completeXhs(note, wantedId, looksLikeXhs);
}

/// Build the unified note output from an already-located note object.
ParseResult buildNoteFromRecord(Map<String, Object?> note, String noteId) {
  Object? userObj = note['user'];
  if (!_isRecord(userObj)) userObj = note['author'];
  final user = _isRecord(userObj) ? (userObj as Map).cast<String, Object?>() : <String, Object?>{};
  final author = PostAuthor(
    name: _pickString(user, const ['nickname', 'nickName', 'name', 'userName']),
    id: _pickString(user, const ['userId', 'user_id', 'id', 'redId']),
  );

  final rawImages = note['imageList'] is List ? note['imageList'] as List : (note['images'] as List? ?? []);
  final images = [for (final e in rawImages) if (_isRecord(e)) (e as Map).cast<String, Object?>()];

  final noteType = note['type'] is String ? note['type'] as String : '';
  final firstHasStream = images.isNotEmpty &&
      ((images[0].containsKey('stream')) || images[0].containsKey('livePhoto'));
  final videoObj = note['video'];
  var hasMainVideo = false;
  if (_isRecord(videoObj)) {
    final v = (videoObj as Map).cast<String, Object?>();
    final consumer = v['consumer'];
    hasMainVideo = _nonBlank(v['originVideoKey']) ||
        (_isRecord(consumer) &&
            _nonBlank(((consumer as Map).cast<String, Object?>())['originVideoKey'])) ||
        _collectStreamCandidates(v['media']).isNotEmpty ||
        _collectStreamCandidates(v['stream']).isNotEmpty ||
        (v['mediaV2'] is String &&
            ((v['mediaV2'] as String).contains('master_url') ||
                (v['mediaV2'] as String).contains('masterUrl')));
  }
  final isVideoNote =
      noteType == 'video' || (noteType == '' && hasMainVideo && images.length <= 1 && !firstHasStream);

  final items = <MediaItem>[];

  if (isVideoNote) {
    final resolved = resolveVideoUrl(note['video']);
    if (resolved != null) {
      items.add(MediaItem(type: 'video', url: resolved.url, width: resolved.width, height: resolved.height));
    } else if (images.length == 1) {
      final img = _imageUrlOf(images[0]);
      if (img != null) {
        items.add(MediaItem(
            type: 'image',
            url: img.url,
            width: _asInt(images[0]['width']),
            height: _asInt(images[0]['height']),
            fallbacks: img.fallbacks));
      }
    }
  } else {
    final noteVideo = resolveVideoUrl(note['video']);
    var noteVideoEmitted = false;
    for (final entry in images) {
      final img = _imageUrlOf(entry);
      final livePhoto = entry['livePhoto'];
      final livePhotoMap =
          livePhoto is Map<String, Object?> ? livePhoto : null;
      final entryKey = _pickString(entry, const ['originVideoKey']) ??
          (livePhotoMap != null
              ? _pickString(livePhotoMap, const ['originVideoKey'])
              : null);
      String? entryKeyUrl;
      if (entryKey != null) {
        entryKeyUrl = RegExp(r'^https?://', caseSensitive: false).hasMatch(entryKey)
            ? toHttps(entryKey)
            : 'https://sns-video-bd.xhscdn.com/${entryKey.replaceFirst(RegExp(r'^/+'), '')}';
      }
      final ownCandidates = [
        ..._collectStreamCandidates(entry['stream']),
        if (livePhotoMap != null && livePhotoMap.containsKey('stream'))
          ..._collectStreamCandidates(livePhotoMap['stream']),
      ];
      final _VideoCandidate? own = entryKeyUrl != null
          ? _VideoCandidate(url: entryKeyUrl, watermarked: false, width: 0, height: 0)
          : _bestVideo(ownCandidates);
      if (own != null && img != null) {
        items.add(MediaItem(
            type: 'live',
            url: img.url,
            videoUrl: own.url,
            width: _asInt(entry['width']),
            height: _asInt(entry['height']),
            fallbacks: img.fallbacks));
        continue;
      }
      if (own != null && img == null) {
        items.add(MediaItem(type: 'video', url: own.url));
        continue;
      }
      if (img != null) {
        items.add(MediaItem(
            type: 'image',
            url: img.url,
            width: _asInt(entry['width']),
            height: _asInt(entry['height']),
            fallbacks: img.fallbacks));
      }
    }
    if (noteVideo != null && !noteVideoEmitted && images.length != 1) {
      noteVideoEmitted = true;
      items.add(MediaItem(
          type: 'video', url: noteVideo.url, width: noteVideo.width, height: noteVideo.height));
    }
  }

  if (items.isEmpty) {
    return ParseResult.err(ParseError(
      code: ParseErrorCode.loginRequired,
      message: 'Xiaohongshu note has no extractable media.',
    ));
  }

  final time = note['time'];
  return ParseResult.ok(ParsedPost(
    platform: 'xhs',
    id: noteId,
    url: 'https://www.xiaohongshu.com/explore/$noteId',
    author: author,
    items: items,
    title: _nonBlank(note['title']) ? note['title'] as String : null,
    caption: _pickString(note, const ['desc', 'description']),
    publishedAt: time is num && time.isFinite ? _toIsoUtc(time.toInt()) : null,
  ));
}
