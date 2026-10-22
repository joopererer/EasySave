// Copyright 2026 EasySave. All rights reserved.
// Tier 3 SAF folder backup service, rotation logic, and platform channel bridge.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import '../../core/dev_log.dart';
import '../history_db.dart';
import '../settings.dart';
import 'backup_service.dart';

/// Base exception for all SAF (Storage Access Framework) operations.
sealed class SafException implements Exception {
  final String message;
  const SafException(this.message);

  @override
  String toString() => '$runtimeType: $message';
}

/// Thrown when URI permission was revoked, lost, or write is denied.
class SafPermissionException extends SafException {
  const SafPermissionException([super.message = 'SAF permission lost or revoked']);
}

/// Thrown when the target directory does not exist or was deleted.
class SafDirectoryNotFoundException extends SafException {
  const SafDirectoryNotFoundException([super.message = 'Target directory does not exist']);
}

/// Thrown when the target storage volume is full.
class SafStorageFullException extends SafException {
  const SafStorageFullException([super.message = 'Storage volume is full']);
}

/// Thrown when read-back verification of a written backup file fails
/// (e.g. format mismatch, version mismatch, or posts count mismatch).
class SafVerificationException extends SafException {
  const SafVerificationException([super.message = 'Backup read-back verification failed']);
}

/// General I/O exception during SAF read/write operations.
class SafIOException extends SafException {
  const SafIOException([super.message = 'I/O failure during SAF operation']);
}

/// Strict regex matching backup filenames: easysave-backup-YYYYMMDD-HHmm.json
final RegExp kBackupFilenameRegExp = RegExp(r'^easysave-backup-(\d{8}-\d{4})\.json$');

/// Extracts the timestamp string YYYYMMDD-HHmm if the filename strictly matches.
/// Returns null for any non-matching files (e.g. photos, other backups).
String? extractBackupTimestamp(String fileName) {
  final match = kBackupFilenameRegExp.firstMatch(fileName);
  return match?.group(1);
}

/// Formats a DateTime into a strict backup filename:
/// `easysave-backup-YYYYMMDD-HHmm.json`
String formatBackupFileName(DateTime time) {
  final y = time.year.toString().padLeft(4, '0');
  final m = time.month.toString().padLeft(2, '0');
  final d = time.day.toString().padLeft(2, '0');
  final h = time.hour.toString().padLeft(2, '0');
  final min = time.minute.toString().padLeft(2, '0');
  return 'easysave-backup-$y$m$d-$h$min.json';
}

/// Pure helper to determine which files should be pruned during rotation.
/// - Only files matching [kBackupFilenameRegExp] are considered.
/// - Sorts descending by timestamp.
/// - Returns candidate filenames beyond [keepCount] (default 7).
/// - Non-matching files are NEVER included.
List<String> getPruneCandidates(List<String> fileNames, {int keepCount = 7}) {
  final matching = <MapEntry<String, String>>[];
  for (final name in fileNames) {
    final ts = extractBackupTimestamp(name);
    if (ts != null) {
      matching.add(MapEntry(ts, name));
    }
  }

  // Sort descending by timestamp string
  matching.sort((a, b) => b.key.compareTo(a.key));

  if (matching.length <= keepCount) {
    return const [];
  }

  return matching.sublist(keepCount).map((e) => e.value).toList();
}

abstract final class SafService {
  static const MethodChannel _channel = MethodChannel('easysave/saf');
  static const throttleDuration = Duration(hours: 1);
  static int? _lastSafBackupTimestampMs;

  /// Resets throttling state (for unit testing).
  static void resetThrottleForTest() {
    _lastSafBackupTimestampMs = null;
  }

  /// Launch system folder picker (ACTION_OPEN_DOCUMENT_TREE) with persistable flags.
  /// Returns the persisted Tree URI string, or null if cancelled.
  static Future<String?> pickDirectory({MethodChannel? channelOverride}) async {
    final ch = channelOverride ?? _channel;
    try {
      final uri = await ch.invokeMethod<String>('pickDirectory');
      return uri;
    } on PlatformException catch (e) {
      DevLog.write('SAF', 'pickDirectory error: ${e.message}', level: DevLogLevel.error);
      throw _mapPlatformException(e);
    }
  }

  /// Launch system file picker (ACTION_OPEN_DOCUMENT) to pick a backup JSON file.
  /// Returns Document URI string, or null if cancelled.
  static Future<String?> pickBackupFile({MethodChannel? channelOverride}) async {
    final ch = channelOverride ?? _channel;
    try {
      final uri = await ch.invokeMethod<String>('pickBackupFile');
      return uri;
    } on PlatformException catch (e) {
      DevLog.write('SAF', 'pickBackupFile error: ${e.message}', level: DevLogLevel.error);
      throw _mapPlatformException(e);
    }
  }

  /// Check whether the persisted Tree URI still has valid read/write permission.
  static Future<bool> checkDirectoryAccess(
    String treeUri, {
    MethodChannel? channelOverride,
  }) async {
    final ch = channelOverride ?? _channel;
    try {
      final hasAccess = await ch.invokeMethod<bool>('checkDirectoryAccess', {
        'treeUri': treeUri,
      });
      return hasAccess ?? false;
    } catch (e) {
      DevLog.write('SAF', 'checkDirectoryAccess error: $e', level: DevLogLevel.warn);
      return false;
    }
  }

  /// Read the full text content of a Document URI.
  static Future<String> readDocumentContent(
    String uri, {
    MethodChannel? channelOverride,
  }) async {
    final ch = channelOverride ?? _channel;
    try {
      final content = await ch.invokeMethod<String>('readDocumentContent', {
        'uri': uri,
      });
      if (content == null) {
        throw const SafIOException('Empty document content');
      }
      return content;
    } on PlatformException catch (e) {
      DevLog.write('SAF', 'readDocumentContent error: ${e.message}', level: DevLogLevel.error);
      throw _mapPlatformException(e);
    }
  }

  /// Write a backup file to the target tree directory.
  static Future<String> writeBackupToDirectory(
    String treeUri,
    String fileName,
    String content, {
    MethodChannel? channelOverride,
  }) async {
    final ch = channelOverride ?? _channel;
    try {
      final fileUri = await ch.invokeMethod<String>('writeBackupToDirectory', {
        'treeUri': treeUri,
        'fileName': fileName,
        'content': content,
      });
      if (fileUri == null) {
        throw const SafIOException('Failed to obtain written document URI');
      }
      return fileUri;
    } on PlatformException catch (e) {
      DevLog.write('SAF', 'writeBackupToDirectory error: ${e.message}', level: DevLogLevel.error);
      throw _mapPlatformException(e);
    }
  }

  /// Prune old backups in the directory via platform channel.
  static Future<int> rotateBackups(
    String treeUri, {
    MethodChannel? channelOverride,
  }) async {
    final ch = channelOverride ?? _channel;
    try {
      final pruned = await ch.invokeMethod<int>('rotateBackups', {
        'treeUri': treeUri,
      });
      return pruned ?? 0;
    } on PlatformException catch (e) {
      DevLog.write('SAF', 'rotateBackups error: ${e.message}', level: DevLogLevel.warn);
      throw _mapPlatformException(e);
    }
  }

  /// Writes backup JSON to target tree directory, reads back and verifies
  /// (format, formatVersion, postCount), and ONLY then triggers rotation.
  /// Throws [SafVerificationException] or [SafException] on failure.
  static Future<String> writeAndVerifyBackup({
    required String treeUri,
    required String fileName,
    required String content,
    required int expectedPostCount,
    MethodChannel? channelOverride,
  }) async {
    // 1. Write new file (or overwrite existing same-name file with "wt")
    final fileUri = await writeBackupToDirectory(
      treeUri,
      fileName,
      content,
      channelOverride: channelOverride,
    );

    // 2. Read back & verify
    final readBackContent = await readDocumentContent(
      fileUri,
      channelOverride: channelOverride,
    );

    final Map<String, dynamic> readBackData;
    try {
      final decoded = jsonDecode(readBackContent);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Root is not a JSON object');
      }
      readBackData = decoded;
    } catch (e) {
      throw SafVerificationException('Failed to parse read-back backup JSON: $e');
    }

    if (readBackData['format'] != 'easysave-backup') {
      throw SafVerificationException(
        "Invalid format in read-back backup: ${readBackData['format']}",
      );
    }
    if (readBackData['formatVersion'] != 1) {
      throw SafVerificationException(
        "Invalid formatVersion in read-back backup: ${readBackData['formatVersion']}",
      );
    }
    final readPosts = readBackData['posts'] as List?;
    if (readPosts == null || readPosts.length != expectedPostCount) {
      throw SafVerificationException(
        'Post count mismatch: expected $expectedPostCount, got ${readPosts?.length}',
      );
    }

    // 3. Verification passed: prune / rotate old backups
    await rotateBackups(treeUri, channelOverride: channelOverride);

    return fileUri;
  }

  /// Perform automatic backup to the user's selected SAF folder.
  /// Returns true if written, false if skipped (e.g. not configured, throttled, or empty history).
  static Future<bool> performAutoBackupToDirectory({
    HistoryDb? db,
    AppSettings? settings,
    DateTime? now,
    bool force = false,
    MethodChannel? channelOverride,
  }) async {
    final currentSettings = settings ?? await AppSettings.load();
    final treeUri = currentSettings.backupTreeUri;
    if (treeUri == null || treeUri.isEmpty) {
      return false;
    }

    final store = db ?? await HistoryDb.instance();
    if (await BackupService.isHistoryEmpty(db: store)) {
      // Empty history protection (§4.3):
      // When history is empty, Tier 3 auto-backup MUST NOT write any file
      // and MUST NOT run rotation pruning, preserving existing backups.
      return false;
    }

    final currentTime = now ?? DateTime.now();
    if (!force && _lastSafBackupTimestampMs != null) {
      final elapsed = currentTime.difference(
        DateTime.fromMillisecondsSinceEpoch(_lastSafBackupTimestampMs!),
      );
      if (elapsed < throttleDuration) {
        return false;
      }
    }

    final jsonContent = await BackupService.exportBackup(
      db: store,
      settings: currentSettings,
      now: currentTime,
    );
    final decoded = jsonDecode(jsonContent) as Map<String, dynamic>;
    final expectedPostCount = (decoded['posts'] as List).length;

    final fileName = formatBackupFileName(currentTime);
    await writeAndVerifyBackup(
      treeUri: treeUri,
      fileName: fileName,
      content: jsonContent,
      expectedPostCount: expectedPostCount,
      channelOverride: channelOverride,
    );

    _lastSafBackupTimestampMs = currentTime.millisecondsSinceEpoch;
    try {
      currentSettings.lastBackupTime = currentTime.millisecondsSinceEpoch;
      await currentSettings.save();
    } catch (_) {
      // Best effort saving lastBackupTime
    }
    return true;
  }

  /// Manual "立即备份" action to target SAF directory.
  static Future<String> performManualBackupToDirectory(
    String treeUri, {
    HistoryDb? db,
    AppSettings? settings,
    DateTime? now,
    MethodChannel? channelOverride,
  }) async {
    final store = db ?? await HistoryDb.instance();
    final currentSettings = settings ?? await AppSettings.load();
    final currentTime = now ?? DateTime.now();

    final jsonContent = await BackupService.exportBackup(
      db: store,
      settings: currentSettings,
      now: currentTime,
    );
    final decoded = jsonDecode(jsonContent) as Map<String, dynamic>;
    final expectedPostCount = (decoded['posts'] as List).length;

    final fileName = formatBackupFileName(currentTime);
    final fileUri = await writeAndVerifyBackup(
      treeUri: treeUri,
      fileName: fileName,
      content: jsonContent,
      expectedPostCount: expectedPostCount,
      channelOverride: channelOverride,
    );

    _lastSafBackupTimestampMs = currentTime.millisecondsSinceEpoch;
    try {
      currentSettings.lastBackupTime = currentTime.millisecondsSinceEpoch;
      await currentSettings.save();
    } catch (_) {
      // Best effort saving lastBackupTime
    }
    return fileUri;
  }

  static SafException _mapPlatformException(PlatformException e) {
    switch (e.code) {
      case 'PERMISSION_LOST':
        return SafPermissionException(e.message ?? 'SAF permission lost or revoked');
      case 'DIRECTORY_NOT_FOUND':
        return SafDirectoryNotFoundException(e.message ?? 'Selected directory not found');
      case 'STORAGE_FULL':
        return SafStorageFullException(e.message ?? 'Storage is full');
      default:
        return SafIOException(e.message ?? 'I/O failure during SAF operation');
    }
  }
}
