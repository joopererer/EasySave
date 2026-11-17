import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../core/dev_log.dart';

/// Minimum byte size for resumable downloads (5MB). Smaller files (< 5MB)
/// transfer in a few hundred milliseconds; the protocol and disk overhead of
/// Range negotiation, partial file tracking, and validator state exceeds the
/// bandwidth savings, so small files maintain simple fail-and-restart.
const int kResumableMinBytes = 5 * 1024 * 1024;

/// Retention period for unfinished partial download files. 3 days provides
/// ample window for intermittent mobile / offline users to resume, while
/// guaranteeing bounded disk usage by purging abandoned transfers.
const Duration kResumeFileMaxAge = Duration(days: 3);

/// Resume metadata saved alongside a partial `.part` file.
class ResumeMetadata {
  const ResumeMetadata({
    required this.validator,
    required this.totalBytes,
    required this.updatedAt,
  });

  final String validator;
  final int totalBytes;
  final int updatedAt;

  Map<String, dynamic> toJson() => {
    'validator': validator,
    'totalBytes': totalBytes,
    'updatedAt': updatedAt,
  };

  static ResumeMetadata? fromJson(Map<String, dynamic> json) {
    final v = json['validator'];
    final t = json['totalBytes'];
    final u = json['updatedAt'];
    if (v is String && t is int && u is int) {
      return ResumeMetadata(validator: v, totalBytes: t, updatedAt: u);
    }
    return null;
  }
}

/// Manages private storage, validator persistence, and lifecycle cleanup for
/// resumable media transfers.
class ResumableDownloadStore {
  ResumableDownloadStore._();
  static final ResumableDownloadStore instance = ResumableDownloadStore._();

  @visibleForTesting
  Directory? overrideDirectory;

  Future<Directory> get _storeDir async {
    if (overrideDirectory != null) return overrideDirectory!;
    final base = await getTemporaryDirectory();
    final dir = Directory('${base.path}/easysave_resumes');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  String _safeKey(String jobKey) =>
      Uri.encodeComponent(jobKey).replaceAll('%', '_');

  Future<File> partialFileFor(String jobKey) async {
    final dir = await _storeDir;
    return File('${dir.path}/${_safeKey(jobKey)}.part');
  }

  Future<File> metaFileFor(String jobKey) async {
    final dir = await _storeDir;
    return File('${dir.path}/${_safeKey(jobKey)}.meta');
  }

  Future<ResumeMetadata?> readMetadata(String jobKey) async {
    try {
      final metaFile = await metaFileFor(jobKey);
      if (!await metaFile.exists()) return null;
      final content = await metaFile.readAsString();
      final decoded = jsonDecode(content);
      if (decoded is Map<String, dynamic>) {
        return ResumeMetadata.fromJson(decoded);
      }
    } catch (_) {
      // Best effort; corrupted metadata triggers clean restart
    }
    return null;
  }

  Future<void> writeMetadata(String jobKey, ResumeMetadata meta) async {
    try {
      final metaFile = await metaFileFor(jobKey);
      await metaFile.parent.create(recursive: true);
      await metaFile.writeAsString(jsonEncode(meta.toJson()), flush: true);
    } catch (_) {
      // Best effort
    }
  }

  Future<void> cleanForJob(String jobKey) async {
    try {
      final part = await partialFileFor(jobKey);
      if (await part.exists()) await part.delete();
    } catch (_) {}
    try {
      final meta = await metaFileFor(jobKey);
      if (await meta.exists()) await meta.delete();
    } catch (_) {}
  }

  Future<void> cleanForJobKeys(Iterable<String> jobKeys) async {
    for (final key in jobKeys) {
      await cleanForJob(key);
    }
  }

  /// Purges partial and metadata files exceeding [maxAge].
  Future<int> purgeExpired({Duration maxAge = kResumeFileMaxAge}) async {
    var purged = 0;
    try {
      final dir = await _storeDir;
      if (!await dir.exists()) return 0;
      final now = DateTime.now();
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        try {
          final stat = await entity.stat();
          if (now.difference(stat.modified) > maxAge) {
            await entity.delete();
            purged++;
          }
        } catch (_) {}
      }
    } catch (_) {}
    return purged;
  }

  /// Structured log for resume events.
  /// Result: 'resumed' or 'restart'
  /// Reason: 'range_accepted', 'no_range', 'validator_changed', 'status_200', 'expired', etc.
  static void logResume({
    required int index,
    required String role,
    required int fromBytes,
    required int total,
    required String result,
    required String reason,
  }) {
    unawaited(DevLog.write(
      'V16DL',
      'resume index=$index role=$role from_bytes=$fromBytes total=$total result=$result reason=$reason',
    ));
  }
}
