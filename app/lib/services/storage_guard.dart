// Free-space checks and disk-full detection for downloads.
//
// A finished download needs its temp file plus the album copy (the provenance
// rewrite of a video replaces the temp file), so a download of N bytes needs
// about 2N free bytes plus a margin for the database and other writes.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Error code of a download that failed for lack of storage.
const storageFullCode = 'STORAGE_FULL';

/// Space kept free beyond the download itself (database, provenance, system).
const int kStorageMarginBytes = 256 * 1024 * 1024;

/// Free bytes a download of [contentLength] bytes needs before it starts.
int requiredBytesForDownload(int contentLength) =>
    contentLength * 2 + kStorageMarginBytes;

/// User-facing copy; [requiredBytes] is shown in GB when known.
String storageFullMessage([int? requiredBytes]) {
  if (requiredBytes == null || requiredBytes <= 0) {
    return '存储空间不足，请清理手机空间后重试';
  }
  final gb = requiredBytes / (1024 * 1024 * 1024);
  final shown = gb < 0.1 ? '0.1' : gb.toStringAsFixed(1);
  return '存储空间不足，需要约 $shown GB';
}

/// A download or write that cannot proceed because storage is full.
class StorageFullException implements Exception {
  const StorageFullException([this.requiredBytes]);

  final int? requiredBytes;

  String get message => storageFullMessage(requiredBytes);

  @override
  String toString() => message;
}

final _diskFullText = RegExp(
  r'no space left|enospc|disk is full|sqlite_full|\(code 13\)|errno = 28|errno 28|storage full',
  caseSensitive: false,
);

/// Whether [error] (an exception or a native error description) means the
/// device ran out of storage: ENOSPC from file writes, SQLITE_FULL from the
/// database, or the plugin's textual description of either.
bool isStorageFullError(Object? error) {
  if (error == null) return false;
  if (error is StorageFullException) return true;
  if (error is FileSystemException && error.osError?.errorCode == 28) {
    return true;
  }
  return _diskFullText.hasMatch(error.toString());
}

abstract final class StorageGuard {
  static const MethodChannel _channel = MethodChannel('easysave/media');

  /// Test seam: free bytes, or null when unknown.
  @visibleForTesting
  static Future<int?> Function()? freeBytesReaderForTesting;

  /// Free bytes on the volume used for temp files and the album (the smaller
  /// of the two when they differ); null when the platform cannot tell.
  static Future<int?> freeBytes() async {
    final test = freeBytesReaderForTesting;
    if (test != null) return test();
    try {
      final info = await _channel.invokeMapMethod<String, Object?>('storageInfo');
      final values = [info?['cacheFree'], info?['externalFree']]
          .whereType<num>()
          .map((v) => v.toInt())
          .where((v) => v >= 0)
          .toList();
      if (values.isEmpty) return null;
      return values.reduce((a, b) => a < b ? a : b);
    } catch (_) {
      return null;
    }
  }

  /// Check [contentLength] against free space. Returns the required bytes when
  /// storage is insufficient, null when the download may start (including when
  /// either size is unknown).
  static Future<int?> shortfall(int? contentLength) async {
    if (contentLength == null || contentLength <= 0) return null;
    final free = await freeBytes();
    if (free == null) return null;
    final required = requiredBytesForDownload(contentLength);
    return free < required ? required : null;
  }
}
