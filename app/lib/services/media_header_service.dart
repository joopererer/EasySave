// Copyright 2026 EasySave. All rights reserved.
// Dart side of the media header channel.
//
// The rebuild scan only needs the header bytes of a file (the XMP lives in
// the JPEG APP1 segment, the PNG iTXt chunk or the WebP "XMP " chunk), so
// the native side streams just those bytes instead of copying whole files.

import 'package:flutter/services.dart';

import '../core/dev_log.dart';

/// Thrown when the platform side is not available (unit tests, desktop).
class MediaHeaderUnavailable implements Exception {
  const MediaHeaderUnavailable(this.message);
  final String message;
  @override
  String toString() => 'MediaHeaderUnavailable: $message';
}

/// One media file's header bytes plus the album MediaStore reports for it.
class MediaHeader {
  const MediaHeader({
    required this.mediaId,
    required this.mimeType,
    required this.bytes,
    this.albumName,
    this.relativePath,
  });

  final String mediaId;
  final String? mimeType;

  /// The bytes that were read (never a byte count).
  final Uint8List bytes;

  /// MediaStore bucket (BUCKET_DISPLAY_NAME) of the file, if known.
  final String? albumName;

  /// MediaStore RELATIVE_PATH of the file, if known.
  final String? relativePath;

  bool get isEmpty => bytes.isEmpty;
}

abstract final class MediaHeaderService {
  static const MethodChannel _channel = MethodChannel('easysave/media');

  static const String logTag = 'V16DL';

  /// Overridable for tests: (mediaId, mimeType) -> bytes.
  static Future<Uint8List> Function(String mediaId, String? mimeType)?
      headerReader;

  /// Overridable for tests: (mediaId) -> (album, relativePath).
  static Future<({String? album, String? relativePath})?> Function(
    String mediaId,
  )? albumReader;

  /// Overridable for tests: (path, mimeType) -> scanned uri.
  static Future<String?> Function(String path, String? mimeType)? scanner;

  /// Trigger MediaScannerConnection.scanFile on [path].
  static Future<String?> scanFile(String path, [String? mimeType]) async {
    final override = scanner;
    if (override != null) return override(path, mimeType);
    try {
      return await _channel.invokeMethod<String>(
        'scanFile',
        {'path': path, 'mimeType': mimeType},
      );
    } catch (e) {
      DevLog.write(logTag, 'scanFile failed for $path: $e'); // i18n:ignore 日志
      return null;
    }
  }

  /// Read the header bytes of a media file.
  ///
  /// Returns an empty list when the platform is unavailable or the file
  /// cannot be read; the caller then skips the file.
  static Future<Uint8List> readHeader(String mediaId, String? mimeType) async {
    final override = headerReader;
    if (override != null) return override(mediaId, mimeType);
    try {
      final raw = await _channel.invokeMethod<Uint8List>(
        'readMediaHeader',
        {'id': mediaId, 'mimeType': mimeType},
      );
      return raw ?? Uint8List(0);
    } on MissingPluginException {
      DevLog.write(
        logTag,
        'readMediaHeader unavailable for $mediaId', // i18n:ignore 日志
        level: DevLogLevel.warn,
      );
      return Uint8List(0);
    } catch (e) {
      DevLog.write(logTag, 'readMediaHeader failed for $mediaId: $e'); // i18n:ignore 日志
      return Uint8List(0);
    }
  }

  /// Album of a media file, as MediaStore reports it.
  ///
  /// The album name is never derived from the file name: it comes from
  /// BUCKET_DISPLAY_NAME / RELATIVE_PATH.
  static Future<({String? album, String? relativePath})?> queryAlbum(
    String mediaId,
  ) async {
    final override = albumReader;
    if (override != null) return override(mediaId);
    try {
      final raw = await _channel.invokeMapMethod<String, String?>(
        'queryMediaAlbum',
        {'id': mediaId},
      );
      if (raw == null) return null;
      return (album: raw['bucket'], relativePath: raw['relativePath']);
    } on MissingPluginException {
      return null;
    } catch (e) {
      DevLog.write(logTag, 'queryMediaAlbum failed for $mediaId: $e'); // i18n:ignore 日志
      return null;
    }
  }
}
