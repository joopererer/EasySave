// What a finished download actually is, read from its own header bytes.
//
// The download plan trusts the parser's URL kinds, but a CDN can answer an
// image URL with an ISO-BMFF HEIC (a Xiaohongshu Live photo still) — which the
// earlier pipeline saved as an unplayable `.mp4` with MP4 provenance. Every
// finished file is identified here before it may reach the album.

import 'dart:io';
import 'dart:typed_data';

enum MediaContentKind { image, video }

/// A concrete container as the file header declares it.
class MediaContentType {
  const MediaContentType(this.kind, this.extension, this.mime, {this.playable});

  final MediaContentKind kind;

  /// Canonical extension for the album file (`jpg`, `heic`, `mp4`, ...).
  final String extension;

  /// MIME type that matches [extension].
  final String mime;

  /// For a video: whether a `moov` box was found. Null when the caller only
  /// inspected the header (no file bytes to scan).
  final bool? playable;

  bool get isImage => kind == MediaContentKind.image;

  bool get isVideo => kind == MediaContentKind.video;

  @override
  String toString() => 'MediaContentType($extension, $mime, playable=$playable)';
}

const _jpeg = MediaContentType(MediaContentKind.image, 'jpg', 'image/jpeg');
const _png = MediaContentType(MediaContentKind.image, 'png', 'image/png');
const _webp = MediaContentType(MediaContentKind.image, 'webp', 'image/webp');
const _gif = MediaContentType(MediaContentKind.image, 'gif', 'image/gif');
const _heic = MediaContentType(MediaContentKind.image, 'heic', 'image/heic');
const _avif = MediaContentType(MediaContentKind.image, 'avif', 'image/avif');
const _mp4 = MediaContentType(MediaContentKind.video, 'mp4', 'video/mp4');
const _mov = MediaContentType(MediaContentKind.video, 'mov', 'video/quicktime');

/// HEIF / HEIC still brands. `mif1` and `msf1` are the generic HEIF wrappers
/// Xiaohongshu serves for iPhone originals.
const _heicBrands = {
  'heic', 'heix', 'hevc', 'hevx', 'heim', 'heis', 'hevm', 'hevs', 'mif1', 'msf1',
};

/// AVIF still brands.
const _avifBrands = {'avif', 'avis'};

/// ISO-BMFF brands that only a movie may declare.
const _videoBrands = {
  'isom', 'iso2', 'iso3', 'iso4', 'iso5', 'iso6', 'iso8', 'iso9',
  'mp41', 'mp42', 'avc1', 'dash', 'M4V ', 'M4VH', 'M4VP', 'MSNV', 'mmp4',
  '3gp4', '3gp5', '3gp6', '3g2a', 'qt  ',
};

/// Top-level box types that may legally open an ISO-BMFF movie.
const _movieBoxTypes = {
  'ftyp', 'styp', 'moov', 'mdat', 'free', 'skip', 'wide', 'junk', 'pnot',
  'sidx', 'moof', 'mfra', 'meta', 'uuid', 'udta',
};

/// Identifies the container from its first bytes. A video result carries
/// `playable: null` here; only [sniffMediaFile] confirms a `moov` box.
MediaContentType? detectMediaContentType(Uint8List bytes) {
  if (bytes.length >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
    return _jpeg;
  }
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47 &&
      bytes[4] == 0x0D &&
      bytes[5] == 0x0A &&
      bytes[6] == 0x1A &&
      bytes[7] == 0x0A) {
    return _png;
  }
  if (bytes.length >= 12 &&
      _fourCc(bytes, 0) == 'RIFF' &&
      _fourCc(bytes, 8) == 'WEBP') {
    return _webp;
  }
  if (bytes.length >= 6 && _fourCc(bytes, 0) == 'GIF8') return _gif;
  return _isoMediaType(bytes);
}

/// ISO base media file format: `ftyp` brands decide the kind. The same `ftyp`
/// box opens HEIC, AVIF and MP4, so the brand — never the box alone — is what
/// separates a still from a movie.
MediaContentType? _isoMediaType(Uint8List bytes) {
  if (bytes.length < 8) return null;
  if (!_movieBoxTypes.contains(_fourCc(bytes, 4))) return null;
  if (_fourCc(bytes, 4) != 'ftyp') {
    // A movie that starts with moov/moof/mdat declares no brand at all.
    return _mp4;
  }
  if (bytes.length < 12) return null;
  final brands = <String>[_fourCc(bytes, 8)];
  final boxSize = ByteData.sublistView(bytes).getUint32(0);
  final end = boxSize >= 16 && boxSize <= bytes.length ? boxSize : bytes.length;
  for (var offset = 16; offset + 4 <= end; offset += 4) {
    brands.add(_fourCc(bytes, offset));
  }
  if (brands.any(_avifBrands.contains)) return _avif;
  if (brands.any(_heicBrands.contains)) return _heic;
  if (brands.first == 'qt  ') return _mov;
  if (brands.any(_videoBrands.contains)) return _mp4;
  return null;
}

/// Identifies a finished download from its own bytes. A movie without a
/// `moov` box is reported with `playable: false` so the caller can reject it.
Future<MediaContentType?> sniffMediaFile(String path) async {
  RandomAccessFile? raf;
  try {
    raf = await File(path).open();
    final length = await raf.length();
    final header = await raf.read(length < 64 ? length : 64);
    final type = detectMediaContentType(header);
    if (type == null || !type.isVideo) return type;
    final moov = await _hasMoovBox(raf, length);
    return MediaContentType(
      type.kind,
      type.extension,
      type.mime,
      playable: moov,
    );
  } catch (_) {
    return null;
  } finally {
    await raf?.close();
  }
}

/// Whether the top-level box chain of [raf] holds a `moov` box. Only box
/// headers are read, so this stays cheap for a large movie.
Future<bool> _hasMoovBox(RandomAccessFile raf, int length) async {
  var offset = 0;
  while (offset + 8 <= length) {
    await raf.setPosition(offset);
    final header = await raf.read(16);
    final size = _boxSize(header, length - offset);
    if (size == null) return false;
    if (_fourCc(header, 4) == 'moov') return true;
    offset += size;
  }
  return false;
}

/// Size of the box whose header is [bytes] with [available] bytes left,
/// including 64-bit and "to the end" forms. Null when the header is unusable.
int? _boxSize(Uint8List bytes, int available) {
  if (bytes.length < 8 || available < 8) return null;
  var size = ByteData.sublistView(bytes).getUint32(0);
  if (size == 1) {
    if (bytes.length < 16) return null;
    size = ByteData.sublistView(bytes).getUint64(8);
  } else if (size == 0) {
    size = available;
  }
  return size >= 8 && size <= available ? size : null;
}

String _fourCc(Uint8List bytes, int offset) =>
    offset + 4 <= bytes.length ? String.fromCharCodes(bytes, offset, offset + 4) : '';

/// Whether provenance can be embedded into a still of [type]. provenance_dart
/// writes XMP into JPEG, PNG and WebP only; every ISO-BMFF still (HEIC, AVIF)
/// and GIF must keep its own bytes instead of going through the MP4 writer.
bool provenanceEmbeddableStill(MediaContentType type) =>
    const {'jpg', 'png', 'webp'}.contains(type.extension);

/// What the download pipeline does with a finished file whose own bytes are
/// [content], for a job that asked for [isImage].
enum ContentVerdict {
  /// The file is what the job asked for: import it.
  accept,

  /// The bytes belong to the other media kind (an image job answered with an
  /// ISO-BMFF movie): the *candidate* is wrong, the next one is tried.
  rejectKind,

  /// A movie without a `moov` box: unusable, the next candidate is tried.
  rejectUnplayable,
}

/// Quality wins over provenance: a still whose container cannot carry
/// provenance (HEIC / AVIF / GIF) is accepted as-is and saved in its own
/// format. It is never a reason to fall back to a preview-size candidate, so
/// [attempts] and [candidateCount] no longer change the verdict — they stay in
/// the signature because every call site reports them in the log.
ContentVerdict contentVerdictFor({
  required bool isImage,
  required int attempts,
  required int candidateCount,
  required MediaContentType? content,
}) {
  // An unreadable header is kept, exactly as before this check existed.
  if (content == null) return ContentVerdict.accept;
  if (content.isImage != isImage) return ContentVerdict.rejectKind;
  if (content.playable == false) return ContentVerdict.rejectUnplayable;
  return ContentVerdict.accept;
}

/// Short label of a candidate URL for the diagnostic log: where the bytes come
/// from and which format the URL advertises. Never the URL itself, its query
/// or anything else that could identify the account.
String candidateLabelOf(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null) return 'unknown';
  final host = uri.host.toLowerCase();
  final String source;
  if (host == 'ci.xiaohongshu.com' || host.startsWith('ci.')) {
    source = 'ci';
  } else if (host.startsWith('sns-img-')) {
    source = 'img';
  } else if (host.startsWith('sns-webpic-')) {
    source = 'webpic';
  } else if (host.startsWith('sns-video-') || uri.path.contains('/stream/')) {
    source = 'video';
  } else {
    source = 'other';
  }
  final path = uri.path.toLowerCase();
  // XHS serves the format as a path-style query segment
  // (`?imageView2/format/jpg`), so the token is read from the whole URL but
  // only ever a short alphanumeric one: nothing else of the query is used.
  var format = RegExp(r'/format/([a-z0-9]{2,5})')
          .firstMatch(url.toLowerCase())
          ?.group(1) ??
      RegExp(r'\.([a-z0-9]{2,5})$').firstMatch(path)?.group(1) ??
      '';
  if (format == 'jpeg') format = 'jpg';
  if (format == 'heif') format = 'heic';
  final safe = RegExp(r'^[a-z0-9]{2,5}$').hasMatch(format) ? format : '';
  return safe.isEmpty ? source : '$source:$safe';
}

/// Whether [url] is a preview-size derivative of a still: the `sns-webpic-*`
/// bucket, a preview scene (`WB_PRV` / `H5_PRV`), a preview style
/// (`!nd_prv_*` / `!h5_prv_*`) or a down-sizing `imageView2` query
/// (`/w/`, `/h/`, `thumbnail`).
///
/// A preview candidate is the last resort: it is only downloaded once every
/// original-resolution candidate of the item failed, and the file it delivers
/// is saved with the existing "非原图" mark.
bool isPreviewStillCandidate(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null) return false;
  final host = uri.host.toLowerCase();
  if (host.startsWith('sns-webpic-')) return true;
  final path = uri.path.toLowerCase();
  final bang = path.indexOf('!');
  if (bang >= 0 && path.substring(bang + 1).contains('prv')) return true;
  final query = uri.query.toLowerCase();
  final all = '$path?$query';
  if (all.contains('wb_prv') || all.contains('h5_prv')) return true;
  if (query.contains('imageview2') &&
      (query.contains('/w/') ||
          query.contains('/h/') ||
          query.contains('thumbnail'))) {
    return true;
  }
  return false;
}

/// Format rank of a still candidate inside one quality class: the writable
/// (provenance-capable) containers are tried before HEIC / AVIF / GIF. Unknown
/// shapes stay in the middle so a CDN the parser does not know is never pushed
/// to the end.
int stillCandidateRank(String url) {
  final label = candidateLabelOf(url);
  final format = label.contains(':') ? label.split(':').last : '';
  final byFormat = switch (format) {
    'jpg' => 0,
    'png' => 1,
    'webp' => 2,
    'heic' || 'avif' || 'gif' => 4,
    _ => 3,
  };
  // Quality class dominates the format: every original-resolution candidate
  // ranks before every preview-size one, so a HEIC original always beats a
  // WebP preview. Inside the original class the format decides, which is what
  // puts a jpeg original before a HEIC one without an extra request.
  return (isPreviewStillCandidate(url) ? 8 : 0) + byFormat;
}

/// Stable quality-first ordering of the still candidates of one item:
/// original-resolution candidates first (jpeg before HEIC / AVIF), then
/// preview-size derivatives. Live photo stills and ordinary images share it.
List<String> rankStillCandidates(Iterable<String> urls) {
  final indexed = urls.toList().indexed.toList();
  indexed.sort((a, b) {
    final byRank = stillCandidateRank(a.$2).compareTo(stillCandidateRank(b.$2));
    return byRank != 0 ? byRank : a.$1.compareTo(b.$1);
  });
  return [for (final (_, url) in indexed) url];
}

/// Media kind of a media URL, from host, path shape and extension. `undefined`
/// equivalents (null) are kept by callers, so an unseen CDN shape never loses
/// a real file. Mirrors the parser's `xhsMediaKindOf`.
MediaContentKind? mediaKindOfUrl(String url) {
  final uri = Uri.tryParse(url.trim().replaceFirst(RegExp(r'^http://'), 'https://'));
  if (uri == null) return null;
  final host = uri.host.toLowerCase();
  final path = uri.path.toLowerCase();
  if (path.contains('/stream/') || RegExp(r'\.(mp4|mov|m4v|webm)$').hasMatch(path)) {
    return MediaContentKind.video;
  }
  if (host.startsWith('sns-video-')) return MediaContentKind.video;
  if (RegExp(r'\.(jpe?g|png|webp|gif|heic|heif|avif)$').hasMatch(path)) {
    return MediaContentKind.image;
  }
  if (host.startsWith('sns-img-') ||
      host.startsWith('sns-webpic-') ||
      host == 'ci.xiaohongshu.com') {
    return MediaContentKind.image;
  }
  return null;
}

/// Keeps only the candidates whose URL kind matches [isImage]. A list that
/// would become empty is returned unchanged: the header check rejects those.
List<String> filterMediaCandidates(List<String> urls, {required bool isImage}) {
  final wanted = isImage ? MediaContentKind.image : MediaContentKind.video;
  final kept = <String>[];
  for (final url in urls) {
    final kind = mediaKindOfUrl(url);
    if (kind == null || kind == wanted) kept.add(url);
  }
  return kept.isEmpty ? urls : kept;
}
