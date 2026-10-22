// Copyright 2026 EasySave. All rights reserved.
// Orchestrator for provenance metadata operations.
// Coordinates format detection, C2PA check, XMP read/write.

import 'dart:io';
import 'dart:typed_data';

import 'c2pa_detector.dart';
import 'date_formatter.dart';
import 'url_normalizer.dart';
import 'xmp_model.dart';
import 'xmp_jpeg.dart';
import 'xmp_png.dart';
import 'xmp_webp.dart';
import 'xmp_core.dart';

/// Classification of metadata embed failures (used for categorizing skip/error reasons).
enum EmbedErrorCode {
  /// File not found on disk.
  fileNotFound,

  /// File format not recognized (magic bytes do not match JPEG/PNG/WebP).
  formatNotRecognized,

  /// File format recognized but write failed (e.g., payload too large, XMP parse error).
  formatUnsupported,

  /// File contains C2PA content credentials; XMP embed skipped per policy.
  c2paDetected,

  /// Write failed for other reasons (I/O, XMP merge error, etc).
  writeFailed,
}

/// Result of a metadata embed operation.
/// 
/// On success (success=true, errorCode=null), the file has been modified.
/// On skip (success=true, errorCode=c2paDetected), the file was not modified.
/// On failure (success=false, errorCode!=null), the file was not modified.
class EmbedResult {
  final bool success;

  /// Error classification; null on success.
  final EmbedErrorCode? errorCode;

  /// Human-readable error message (for logging/display).
  /// Set on skip or failure; null on success.
  final String? errorMessage;

  const EmbedResult({
    required this.success,
    this.errorCode,
    this.errorMessage,
  });

  factory EmbedResult.success() => const EmbedResult(success: true);

  factory EmbedResult.skippedC2pa() => const EmbedResult(
    success: true,
    errorCode: EmbedErrorCode.c2paDetected,
    errorMessage: 'C2PA content credentials detected',
  );

  factory EmbedResult.failure({
    required EmbedErrorCode code,
    required String message,
  }) => EmbedResult(
    success: false,
    errorCode: code,
    errorMessage: message,
  );

  /// Legacy: return true if this is a "format" error (for backfill classification).
  bool get isFormatError =>
      errorCode == EmbedErrorCode.formatNotRecognized ||
      errorCode == EmbedErrorCode.formatUnsupported;

  /// Legacy: return true if this is a C2PA skip.
  bool get skippedC2pa => errorCode == EmbedErrorCode.c2paDetected;
}

/// Metadata service for reading, writing, and managing provenance metadata.
class MetadataService {
  static Future<EmbedResult> embedProvenance({
    required String filePath,
    required XmpProvenance provenance,
    bool checkC2pa = true,
  }) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        return EmbedResult.failure(
          code: EmbedErrorCode.fileNotFound,
          message: 'File not found: $filePath',
        );
      }

      final bytes = await file.readAsBytes();
      final format = _detectFormat(bytes);

      if (format == null) {
        return EmbedResult.failure(
          code: EmbedErrorCode.formatNotRecognized,
          message: 'Unknown file format: $filePath',
        );
      }

      // Check for C2PA content credentials
      if (checkC2pa) {
        final c2paStatus = detectC2pa(bytes, format);
        if (c2paStatus == C2paStatus.detected) {
          return EmbedResult.skippedC2pa();
        }
      }

      // Read existing XMP and merge
      final existing = _readExisting(bytes, format);
      final merged = mergeXmp(existing, provenance);

      // Write back
      final modified = _writeXmp(bytes, merged, format);
      if (modified == null) {
        return EmbedResult.failure(
          code: EmbedErrorCode.formatUnsupported,
          message: 'Write not supported for format: $format',
        );
      }

      await file.writeAsBytes(modified);
      return EmbedResult.success();
    } catch (e) {
      return EmbedResult.failure(
        code: EmbedErrorCode.writeFailed,
        message: 'Write failed: $e',
      );
    }
  }

  /// Read provenance metadata from a file.
  /// Returns null if no XMP found.
  static XmpProvenance? readProvenance(String filePath) {
    try {
      final file = File(filePath);
      if (!file.existsSync()) return null;

      final bytes = file.readAsBytesSync();
      final format = _detectFormat(bytes);
      if (format == null) return null;

      return _readExisting(bytes, format);
    } catch (_) {
      return null;
    }
  }

  /// Check if a file has C2PA content credentials.
  static bool hasC2pa(String filePath) {
    try {
      final file = File(filePath);
      if (!file.existsSync()) return false;

      final bytes = file.readAsBytesSync();
      final format = _detectFormat(bytes);
      if (format == null) return false;

      return detectC2pa(bytes, format) == C2paStatus.detected;
    } catch (_) {
      return false;
    }
  }

  /// Detect file format from magic bytes.
  static String? _detectFormat(Uint8List bytes) {
    // JPEG: starts with FF D8
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8) {
      return 'JPEG';
    }

    // PNG: starts with 89 50 4E 47
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 && bytes[1] == 0x50 &&
        bytes[2] == 0x4E && bytes[3] == 0x47) {
      return 'PNG';
    }

    // WebP: RIFF....WEBP
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 && bytes[1] == 0x49 &&
        bytes[2] == 0x46 && bytes[3] == 0x46 &&
        bytes[8] == 0x57 && bytes[9] == 0x45 &&
        bytes[10] == 0x42 && bytes[11] == 0x50) {
      return 'WebP';
    }

    return null;
  }

  /// Read existing XMP from file.
  static XmpProvenance? _readExisting(Uint8List bytes, String format) {
    switch (format) {
      case 'JPEG':
        return readJpegXmp(bytes);
      case 'PNG':
        return readPngXmp(bytes);
      case 'WebP':
        return readWebpXmp(bytes);
      default:
        return null;
    }
  }

  /// Read provenance from a **header byte buffer**.
  ///
  /// The rebuild scan streams only the header of each file (the native side
  /// returns the bytes it read, not a byte count), so the format is detected
  /// from the magic bytes and the matching XMP reader is used.
  ///
  /// The PNG and WebP readers expect the container to start at the file
  /// beginning, which is what the native side returns: the PNG signature plus
  /// the XMP chunk, the RIFF header plus the XMP chunk.
  static XmpProvenance? readProvenanceFromBytes(Uint8List bytes) {
    if (bytes.isEmpty) return null;
    final format = _detectFormat(bytes);
    if (format == null) return null;
    try {
      return _readExisting(bytes, format);
    } on FormatException {
      // A truncated header is not an error: the file simply has no readable
      // XMP in the part we fetched.
      return null;
    }
  }

  /// Write XMP to file.
  static Uint8List? _writeXmp(Uint8List bytes, XmpProvenance xmp, String format) {
    switch (format) {
      case 'JPEG':
        return writeJpegXmp(bytes, xmp);
      case 'PNG':
        return writePngXmp(bytes, xmp);
      case 'WebP':
        return writeWebpXmp(bytes, xmp);
      default:
        return null;
    }
  }
}

/// Builder for creating XmpProvenance from download context.
class ProvenanceBuilder {
  final String platform;
  final String postId;
  final String postUrl;
  final String? authorId;
  final String? authorName;
  final String? title;
  final String? caption;
  final DateTime? publishedAt;
  final int itemIndex;
  final int itemCount;
  final String? existingAssetId;

  /// Original save time. When null, the current time is used (fresh download).
  /// Backfill passes the savedAt recorded in files_json.
  final DateTime? capturedAt;

  ProvenanceBuilder({
    required this.platform,
    required this.postId,
    required this.postUrl,
    this.authorId,
    this.authorName,
    this.title,
    this.caption,
    this.publishedAt,
    required this.itemIndex,
    required this.itemCount,
    this.existingAssetId,
    this.capturedAt,
  });

  /// Build XmpProvenance for embedding.
  XmpProvenance build() {
    final now = DateTime.now();
    final specPlatform = toSpecPlatform(platform);
    
    return XmpProvenance(
      schema: '0.1',
      assetId: existingAssetId ?? _generateAssetId(),
      capturedAt: capturedAt ?? now,
      capturedBy: 'EasySave/1.7.0',
      metadataDate: now,
      sourceUrl: _normalizeUrl(postUrl, this.platform),
      platform: specPlatform,
      sourceId: postId,
      itemIndex: itemCount > 1 ? itemIndex : null,
      itemCount: itemCount > 1 ? itemCount : null,
      // For X platform, author.id is the username (e.g., n8_AIart) which is not
      // a stable numeric ID per the spec. Only write authorId if it looks like
      // a numeric ID or is provided by non-X platforms. X platform may have
      // numeric IDs in future if the parser provides them.
      authorId: _shouldWriteAuthorId(platform, authorId) ? authorId : null,
      publishedAt: publishedAt,
      title: title,
      creators: authorName != null ? [authorName!] : null,
      description: caption != null && caption!.length > 2000
          ? '${caption!.substring(0, 1997)}…'
          : caption,
      credit: authorName != null ? '$authorName / ${_platformDisplayName(platform)}' : null,
    );
  }

  /// Generate a new asset ID (UUID v4).
  static String _generateAssetId() {
    // Simple UUID v4 generation
    final bytes = List<int>.generate(16, (i) => DateTime.now().microsecondsSinceEpoch ~/ (i + 1) % 256);
    bytes[6] = (bytes[6] & 0x0F) | 0x40; // Version 4
    bytes[8] = (bytes[8] & 0x3F) | 0x80; // Variant 10

    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20, 32)}';
  }

  /// Normalize URL per SPEC §5 using the url_normalizer package.
  static String _normalizeUrl(String url, String platform) {
    // Delegate to the shared url_normalizer for all normalization
    return normalizeUrl(url);
  }

  /// Decide whether to write authorId based on platform and the ID value.
  /// 
  /// Per spec, prov:authorId should be a stable numeric user ID. X platform
  /// currently provides usernames (e.g., n8_AIart) instead of numeric IDs.
  /// We only write authorId when:
  /// 1. It's provided (not null/empty), AND
  /// 2. Either the platform is NOT X, OR the ID is purely numeric (future-proofing)
  /// 
  /// This is documented as a known limitation in v1.7.md.
  static bool _shouldWriteAuthorId(String platform, String? authorId) {
    if (authorId == null || authorId.isEmpty) return false;
    // For non-X platforms, always write (they provide stable IDs)
    if (platform != 'x') return true;
    // For X platform, only write if it's a numeric ID
    // (currently X parser provides username, so this will be null in most cases)
    return RegExp(r'^\d+$').hasMatch(authorId);
  }

  /// Get display name for platform (app internal identifier).
  static String _platformDisplayName(String appPlatform) {
    return platformDisplayName(appPlatform);
  }
}
