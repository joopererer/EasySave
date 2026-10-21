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

/// Result of a metadata embed operation.
class EmbedResult {
  final bool success;
  final String? error;
  final bool skippedC2pa;

  const EmbedResult({
    required this.success,
    this.error,
    this.skippedC2pa = false,
  });

  factory EmbedResult.success() => const EmbedResult(success: true);

  factory EmbedResult.skipped({String? reason}) => EmbedResult(
    success: true,
    skippedC2pa: reason == 'C2PA',
    error: reason,
  );

  factory EmbedResult.failure(String error) => EmbedResult(
    success: false,
    error: error,
  );
}

/// Metadata service for reading, writing, and managing provenance metadata.
class MetadataService {
  /// Embed provenance metadata into a file.
  /// Returns EmbedResult indicating success, skip (C2PA), or failure.
  /// 
  /// This method:
  /// 1. Reads the file bytes
  /// 2. Detects format
  /// 3. Checks for C2PA signatures
  /// 4. Reads existing XMP (if any)
  /// 5. Merges with new provenance data
  /// 6. Writes back to the file
  /// 
  /// Failures are logged but do not throw - the file save continues.
  static Future<EmbedResult> embedProvenance({
    required String filePath,
    required XmpProvenance provenance,
    bool checkC2pa = true,
  }) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        return EmbedResult.failure('File not found: $filePath');
      }

      final bytes = await file.readAsBytes();
      final format = _detectFormat(bytes);

      if (format == null) {
        return EmbedResult.failure('Unknown file format: $filePath');
      }

      // Check for C2PA content credentials
      if (checkC2pa) {
        final c2paStatus = detectC2pa(bytes, format);
        if (c2paStatus == C2paStatus.detected) {
          return EmbedResult.skipped(reason: 'C2PA');
        }
      }

      // Read existing XMP and merge
      final existing = _readExisting(bytes, format);
      final merged = mergeXmp(existing, provenance);

      // Write back
      final modified = _writeXmp(bytes, merged, format);
      if (modified == null) {
        return EmbedResult.failure('Write failed for format: $format');
      }

      await file.writeAsBytes(modified);
      return EmbedResult.success();
    } catch (e) {
      return EmbedResult.failure('$e');
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
  });

  /// Build XmpProvenance for embedding.
  XmpProvenance build() {
    final now = DateTime.now();
    final specPlatform = toSpecPlatform(platform);
    
    return XmpProvenance(
      schema: '0.1',
      assetId: existingAssetId ?? _generateAssetId(),
      capturedAt: now,
      capturedBy: 'EasySave/1.7.0',
      metadataDate: now,
      sourceUrl: _normalizeUrl(postUrl, this.platform),
      platform: specPlatform,
      sourceId: postId,
      itemIndex: itemCount > 1 ? itemIndex : null,
      itemCount: itemCount > 1 ? itemCount : null,
      authorId: authorId,
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
    // Convert app platform identifier to spec platform name for normalization
    final specPlatform = toSpecPlatform(platform);
    
    // First normalize the URL using the shared normalizer (handles tracking params, etc.)
    var normalized = normalizeUrl(url);
    
    // Apply platform-specific normalization to get canonical form
    // The normalizeUrl function handles most cases, but we need to ensure
    // the output matches SPEC §5 exactly for xiaohongshu and x
    if (specPlatform == 'xiaohongshu') {
      // Extract noteId from various URL formats and produce canonical form
      // normalizeUrl already does this, but we verify here
      final match = RegExp(r'/explore/([a-f0-9]+)').firstMatch(normalized);
      if (match != null) {
        return 'https://www.xiaohongshu.com/explore/${match.group(1)}';
      }
      // Also check for /discovery/item/{id}
      final discoveryMatch = RegExp(r'/discovery/item/([a-f0-9]+)').firstMatch(normalized);
      if (discoveryMatch != null) {
        return 'https://www.xiaohongshu.com/explore/${discoveryMatch.group(1)}';
      }
    } else if (specPlatform == 'x') {
      // Ensure X URLs use the canonical /i/status/{id} form
      final match = RegExp(r'x\.com/[^/]+/status/(\d+)').firstMatch(normalized);
      if (match != null) {
        return 'https://x.com/i/status/${match.group(1)}';
      }
      // Already in canonical form?
      if (normalized.contains('x.com/i/status/')) {
        return normalized;
      }
    }

    return normalized;
  }

  /// Get display name for platform (app internal identifier).
  static String _platformDisplayName(String appPlatform) {
    return platformDisplayName(appPlatform);
  }
}
