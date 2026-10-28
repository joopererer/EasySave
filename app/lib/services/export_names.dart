import 'dart:io';
import '../metadata/metadata_service.dart';

String cleanMediaFilename(String postId, int index, String extension) {
  if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(postId) ||
      index < 1 ||
      !{'jpg', 'jpeg', 'png', 'webp', 'mp4', 'mov'}.contains(extension)) {
    throw ArgumentError('Invalid media identity');
  }
  return '${postId}_$index.$extension';
}

String exportMime(MediaFormat format) => switch (format) {
  MediaFormat.jpeg => 'image/jpeg',
  MediaFormat.png => 'image/png',
  MediaFormat.webp => 'image/webp',
  MediaFormat.mp4 => 'video/mp4',
  _ => throw StateError('该格式无法保存来源信息'),
};

Future<String> exportNameFor(String path, String postId, int index) async {
  final format = await MetadataService.detectFormat(path);
  final ext = switch (format) {
    MediaFormat.jpeg => 'jpg',
    MediaFormat.png => 'png',
    MediaFormat.webp => 'webp',
    MediaFormat.mp4 => 'mp4',
    _ => File(path).uri.pathSegments.last.split('.').last.toLowerCase(),
  };
  return cleanMediaFilename(postId, index, ext);
}
