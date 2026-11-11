import 'dart:io';
import 'media_content_type.dart';

/// Album file name for one item. The extension is a closed set because it also
/// encodes the media identity the album lookup and history rows compare.
String cleanMediaFilename(String postId, int index, String extension) {
  if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(postId) ||
      index < 1 ||
      !{'jpg', 'jpeg', 'png', 'webp', 'gif', 'heic', 'heif', 'avif', 'mp4', 'mov'}
          .contains(extension)) {
    throw ArgumentError('Invalid media identity');
  }
  return '${postId}_$index.$extension';
}

/// MIME type of the file's actual container: the album entry must not claim
/// `video/mp4` for an image that merely shares the ISO-BMFF box layout.
String exportMime(MediaContentType type) => type.mime;

/// Extension and MIME type of [path], from its own header bytes.
Future<MediaContentType> exportTypeFor(String path) async {
  final type = await sniffMediaFile(path);
  if (type != null) return type;
  throw StateError('该格式无法保存来源信息');
}

/// Album file name for [path], whose extension comes from its real container.
Future<String> exportNameFor(String path, String postId, int index) async {
  final type = await sniffMediaFile(path);
  if (type != null) return cleanMediaFilename(postId, index, type.extension);
  final ext = File(path).uri.pathSegments.last.split('.').last.toLowerCase();
  return cleanMediaFilename(postId, index, ext);
}
