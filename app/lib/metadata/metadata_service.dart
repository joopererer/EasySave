// Copyright 2026 EasySave. All rights reserved.
// Orchestrator for provenance metadata operations in EasySave.
// Delegates container parsing, formatting, and XMP read/write to package:provenance_dart.

import 'dart:io';
import 'dart:typed_data';

import 'package:provenance_dart/provenance_dart.dart' as pkg;
export 'package:provenance_dart/provenance_dart.dart';

import '../core/app_version.dart';
import 'url_normalizer.dart';

/// Metadata service for EasySave, bridging to package:provenance_dart.
class MetadataService {
  /// Test override for embedProvenance.
  static Future<pkg.EmbedResult> Function({
    required String filePath,
    required pkg.XmpProvenance provenance,
    bool checkC2pa,
    pkg.Mp4WriteMode mp4WriteMode,
  })? embedOverride;

  /// Embed provenance into a file in App private storage.
  /// Uses provenance_dart's file rewrite (.tmp + rename) or inPlace mode.
  static Future<pkg.EmbedResult> embedProvenance({
    required String filePath,
    required pkg.XmpProvenance provenance,
    bool checkC2pa = true,
    pkg.Mp4WriteMode mp4WriteMode = pkg.Mp4WriteMode.rewrite,
  }) {
    final override = embedOverride;
    if (override != null) {
      return override(
        filePath: filePath,
        provenance: provenance,
        checkC2pa: checkC2pa,
        mp4WriteMode: mp4WriteMode,
      );
    }
    return pkg.MetadataService.embedProvenance(
      filePath: filePath,
      provenance: provenance,
      checkC2pa: checkC2pa,
      mp4WriteMode: mp4WriteMode,
    );
  }

  /// Read provenance metadata from a file (embedded or sidecar).
  static Future<pkg.XmpProvenance?> readProvenance(String filePath) {
    return pkg.MetadataService.readProvenance(filePath);
  }

  /// Check if a file has C2PA content credentials.
  static Future<bool> hasC2pa(String filePath) async {
    return pkg.MetadataService.hasC2pa(filePath);
  }

  /// Detect container format from a file path.
  static Future<pkg.MediaFormat> detectFormat(String filePath) {
    return pkg.MetadataService.detectFormat(filePath);
  }

  /// Read provenance from header bytes (used by rebuild and gallery locator).
  static String? readXmpXmlFromBytes(Uint8List bytes) {
    if (bytes.isEmpty) return null;
    try {
      return switch (pkg.detectFormat(bytes)) {
        pkg.MediaFormat.jpeg => pkg.readJpegXmpText(bytes),
        pkg.MediaFormat.png => pkg.readPngXmpText(bytes),
        pkg.MediaFormat.webp => pkg.readWebpXmpText(bytes),
        pkg.MediaFormat.mp4 => pkg.readMp4XmpText(bytes),
        pkg.MediaFormat.other => null,
      };
    } on FormatException {
      return null;
    }
  }

  static pkg.XmpProvenance? readProvenanceFromBytes(Uint8List bytes) {
    if (bytes.isEmpty) return null;
    final format = pkg.detectFormat(bytes);
    try {
      switch (format) {
        case pkg.MediaFormat.jpeg:
          return pkg.readJpegXmp(bytes);
        case pkg.MediaFormat.png:
          return pkg.readPngXmp(bytes);
        case pkg.MediaFormat.webp:
          return pkg.readWebpXmp(bytes);
        case pkg.MediaFormat.mp4:
          return pkg.readMp4Xmp(bytes);
        case pkg.MediaFormat.other:
          return null;
      }
    } on FormatException {
      return null;
    }
  }

  /// In-memory byte modification for gallery files (does NOT create .tmp files).
  static Uint8List? writeProvenanceToBytes(
    Uint8List bytes,
    pkg.XmpProvenance provenance, {
    bool checkC2pa = true,
  }) {
    if (bytes.isEmpty) return null;
    final format = pkg.detectFormat(bytes);
    if (format == pkg.MediaFormat.other) return null;
    if (checkC2pa && pkg.detectC2pa(bytes, format) == pkg.C2paStatus.detected) {
      return null;
    }
    switch (format) {
      case pkg.MediaFormat.jpeg:
        return pkg.writeJpegXmp(bytes, provenance);
      case pkg.MediaFormat.png:
        return pkg.writePngXmp(bytes, provenance);
      case pkg.MediaFormat.webp:
        return pkg.writeWebpXmp(bytes, provenance);
      case pkg.MediaFormat.mp4:
        return pkg.writeMp4Xmp(bytes, provenance);
      case pkg.MediaFormat.other:
        return null;
    }
  }
}
