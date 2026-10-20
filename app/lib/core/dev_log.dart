// Device log that is easy to collect during manual verification.
//
// Privacy rules (enforced here, not at the call sites):
//   * no cookie / authorization / token / account values — sensitive
//     key=value pairs are replaced with "<redacted>";
//   * URLs are reduced to host + path, so query parameters (xsec_token,
//     share_id, ...) never reach the file;
//   * the file lives in the app's **private** directory (not the external one),
//     is capped at 1 MB and rotates to a single backup file;
//   * release builds only record INFO and above.
//
// Use [DevLog.exportToExternal] to copy the (already redacted) log out of the
// private directory for a bug report.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Severity of a log line.
enum DevLogLevel {
  debug,
  info,
  warn,
  error;

  bool get atLeastInfo => index >= DevLogLevel.info.index;
}

abstract final class DevLog {
  /// Base name of the log file inside the app's private files directory.
  static const String fileName = 'v16dl.log';

  /// Maximum size of the active log file before it is rotated.
  static const int maxFileBytes = 1024 * 1024;

  /// Number of files kept (the active one plus one backup).
  static const int keepFiles = 2;

  static const String _redacted = '<redacted>';


  /// Any http(s) URL inside a message.
  static final RegExp _urlPattern = RegExp(r'''https?://[^\s"'<>]+''');

  /// Write a line to the log file (and to logcat for live debugging).
  ///
  /// [level] defaults to [DevLogLevel.info]; debug lines are dropped in
  /// release builds.
  static Future<void> write(
    String tag,
    String message, {
    DevLogLevel level = DevLogLevel.info,
  }) async {
    if (level == DevLogLevel.debug && kReleaseMode) return;
    final line = '[${level.name.toUpperCase()}] [$tag] ${scrub(message)}';
    debugPrint(line);
    try {
      final dir = await _privateDir();
      if (dir == null) return;
      await _append(File('${dir.path}/$fileName'), line);
    } catch (_) {
      // Logging must never break the caller.
    }
  }

  /// Copy the current log (already redacted) to the app's external files
  /// directory so it can be pulled with adb. Nothing is written there
  /// automatically.
  static Future<String?> exportToExternal() async {
    try {
      final dir = await _privateDir();
      final external = await getExternalStorageDirectory();
      if (dir == null || external == null) return null;
      final source = File('${dir.path}/$fileName');
      if (!await source.exists()) return null;
      final target = File('${external.path}/$fileName');
      await source.copy(target.path);
      return target.path;
    } catch (_) {
      return null;
    }
  }

  /// Remove every log file (app private dir).
  static Future<void> clear() async {
    try {
      final dir = await _privateDir();
      if (dir == null) return;
      for (var i = 0; i < keepFiles; i++) {
        final name = i == 0 ? fileName : '$fileName.$i';
        final f = File('${dir.path}/$name');
        if (await f.exists()) await f.delete();
      }
    } catch (_) {
      // Best effort.
    }
  }

  /// The app's private files directory (internal storage, app only).
  static Future<Directory?> _privateDir() async {
    try {
      final dir = await getApplicationSupportDirectory();
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir;
    } catch (_) {
      return null;
    }
  }

  /// Append a line, rotating when the file grows past [maxFileBytes].
  static Future<void> _append(File file, String line) async {
    final text = '$line\n';
    var length = 0;
    try {
      if (await file.exists()) length = await file.length();
    } catch (_) {
      length = 0;
    }
    if (length + text.length > maxFileBytes) {
      await _rotate(file);
    }
    await file.writeAsString(
      text,
      mode: FileMode.append,
      flush: true,
    );
  }

  /// v16dl.log -> v16dl.log.1 (the previous backup is dropped).
  static Future<void> _rotate(File file) async {
    try {
      final backup = File('${file.path}.1');
      if (await backup.exists()) await backup.delete();
      await file.rename(backup.path);
    } catch (_) {
      // If the rename fails we simply keep appending to the current file.
    }
  }

  /// Remove sensitive data from a message:
  ///   * `cookie=...`, `authorization: ...`, `xsec_token=...` -> `<redacted>`
  ///   * `https://host/path?a=b` -> `host/path`
  static String scrub(String message) {
    var out = message;
    // 1. sensitive key=value / key: value pairs.
    //    The value side allows an optional "Bearer "/"Basic " prefix and
    //    non-separator characters so we grab the whole token-shaped token in
    //    one go (e.g. "authorization: Bearer eyJhbGciOi.J9.sig"). Also
    //    supports quoted values.
    out = out.replaceAllMapped(
      RegExp(
        r'''([A-Za-z0-9_.-]*(?:cookie|authorization|auth|token|password|passwd|secret|session|api[_-]?key|sig|signature)[A-Za-z0-9_.-]*)\s*[=:]\s*(?:(?:Bearer|Basic)\s+)?("[^"]*"|'[^']*'|[^\s,;)]+)''',
        caseSensitive: false,
      ),
      (m) => '${m.group(1)}=$_redacted',
    );
    // 2. fallback for a stray "Bearer xxx" that didn't follow a sensitive
    //    key (e.g. an exception message saying "missing Bearer abc").
    out = out.replaceAllMapped(
      RegExp(
        r'''\b(Bearer|Basic)\s+[A-Za-z0-9._\-]+''',
        caseSensitive: false,
      ),
      (m) => _redacted,
    );
    // 3. URLs -> host + path (no query, no fragment)
    out = out.replaceAllMapped(_urlPattern, (m) => _hostPath(m.group(0)!));
    return out;
  }

  /// `https://host/path?query#frag` -> `host/path`
  static String _hostPath(String url) {
    try {
      final uri = Uri.parse(url);
      if (uri.host.isEmpty) return '<url>';
      final path = uri.path.isEmpty ? '' : uri.path;
      return '${uri.host}$path';
    } catch (_) {
      return '<url>';
    }
  }
}
