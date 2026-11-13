// Read-only check of stills the album already holds.
//
// A HEIC an Android 12 device cannot decode is already in the album of users
// who upgraded from v1.10.2. Re-downloading is the only way to replace one,
// but the card first has to say so — and finding out must not touch the
// blocking decode path that made the history page stall.
//
// Every check goes through [ImageDecodeProbe] (its own native executor, its
// own timeout), runs one file at a time, and only ever reads: the album file
// is never modified, moved or deleted here.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/dev_log.dart';
import 'heif_bytes.dart';
import 'history_db.dart';
import 'image_decode_probe.dart';

/// Containers whose decode depends on the device codecs.
const Set<String> kProbeableStillExtensions = {'heic', 'heif', 'avif'};

/// Containers this build decides from their own bytes, with no decoder at all.
///
/// Only the history pass is restricted to these: an AVIF is still gated by the
/// platform probe when it is saved, but the history pass must not open a decode
/// channel at all (that is what stalled build 46).
const Set<String> kHeifExtensions = {'heic', 'heif'};

String extensionOfStill(String filename) {
  final name = filename.trim().toLowerCase();
  final dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot + 1);
}

/// Whether a stored row still needs its device decodability checked.
bool needsDecodeCheck(HistoryFile file) {
  if (file.undecodable != null) return false;
  if (!file.isImage) return false;
  if (!kProbeableStillExtensions.contains(extensionOfStill(file.filename))) {
    return false;
  }
  final id = file.mediaId;
  return id != null && int.tryParse(id) != null;
}

class HistoryDecodeCheck {
  HistoryDecodeCheck._();

  /// At most this many files are checked per run: a bounded, quiet background
  /// pass, never a burst of decodes on a page that is being read.
  static int maxPerRun = 8;

  /// Replaces the probe in tests.
  @visibleForTesting
  static Future<ImageDecodeResult> Function(String mediaId)? probeForTesting;

  static bool _ranThisSession = false;

  @visibleForTesting
  static void resetForTesting() {
    _ranThisSession = false;
    probeForTesting = null;
  }

  /// Runs the check once per session; safe to call from any page build.
  static Future<void> runOnce() async {
    if (_ranThisSession) return;
    _ranThisSession = true;
    try {
      await check();
    } catch (error) {
      unawaited(DevLog.write(
        'HeicProbe',
        'step=failed reason=${error.runtimeType}',
      ));
    }
  }

  /// One pass over the newest records. Returns how many rows were checked.
  static Future<int> check({List<HistoryRecord>? records}) async {
    final rows = records ?? await (await HistoryDb.instance()).recent(limit: 200);
    final seam = probeForTesting;
    final watch = Stopwatch()..start();
    var checked = 0;
    var rejected = 0;
    var unread = 0;
    for (final record in rows) {
      if (checked >= maxPerRun) break;
      final pending = record.files.where(needsDecodeCheck).toList();
      if (pending.isEmpty) continue;
      final updated = [...record.files];
      var changed = false;
      for (final file in pending) {
        if (checked >= maxPerRun) break;
        checked++;
        final result = seam != null
            ? await seam(file.mediaId!)
            : await probeStoredStill(file.mediaId!, filename: file.filename);
        if (result.verdict == ImageDecodeVerdict.unknown) {
          // No answer is not a verdict: the row keeps whatever it had, so a
          // slow or unreadable file never turns into "missing".
          unread++;
          continue;
        }
        final index = updated.indexOf(file);
        if (index < 0) continue;
        updated[index] = file.copyWith(undecodable: result.isUndecodable);
        changed = true;
        if (result.isUndecodable) rejected++;
      }
      if (!changed) continue;
      final recordId = record.id;
      if (recordId == null) continue;
      try {
        await (await HistoryDb.instance()).updateFiles(
          recordId,
          updated,
          source: 'decode-check',
        );
      } catch (_) {
        // A row that cannot be written is simply checked again next session.
      }
    }
    unawaited(DevLog.write(
      'HeicProbe',
      'step=checked rows=$checked undecodable=$rejected unread=$unread '
          'ms=${watch.elapsedMilliseconds}',
    ));
    return checked;
  }

  /// Decides a stored still from its own header bytes.
  ///
  /// A HEIC/HEIF is never handed to the platform decoder here: an alpha HEIC
  /// makes that decoder hang, and a hung decode is what kept every thumbnail
  /// behind it waiting in build 46. The album file is opened read-only, at most
  /// [kHeifHeadBytes] of it, on the native header reader — no photo_manager
  /// call, no thumbnail request, nothing written. A container this build does
  /// not read itself (AVIF) keeps the previous native probe.
  static Future<ImageDecodeResult> probeStoredStill(
    String mediaId, {
    String filename = '',
  }) async {
    if (filename.isNotEmpty &&
        !kHeifExtensions.contains(extensionOfStill(filename))) {
      // A container this build does not read itself: keep the previous probe.
      return ImageDecodeProbe.probeMediaId(mediaId);
    }
    final bytes = await ImageDecodeProbe.readMediaBytes(mediaId);
    if (bytes.isEmpty) {
      return const ImageDecodeResult(
        ImageDecodeVerdict.unknown,
        reason: heifAlphaUnknownReason,
      );
    }
    final header = parseHeifHeader(bytes);
    final sdk = await ImageDecodeProbe.apiLevel();
    unawaited(DevLog.write('HeifBytes', 'source=album ${header.logFields}'));
    if (heifAlphaUndisplayable(header, sdk)) {
      return ImageDecodeResult(
        ImageDecodeVerdict.undecodable,
        decoder: heifByteDecoder,
        reason: heifAlphaReason,
        bytes: header.bytes,
      );
    }
    if (header.verdict == HeifVerdict.unknown ||
        header.verdict == HeifVerdict.notHeif) {
      // A header this build cannot classify keeps the previous behaviour.
      return ImageDecodeResult(
        ImageDecodeVerdict.unknown,
        decoder: heifByteDecoder,
        reason: heifAlphaUnknownReason,
        bytes: header.bytes,
      );
    }
    return ImageDecodeResult(
      ImageDecodeVerdict.decodable,
      decoder: heifByteDecoder,
      bytes: header.bytes,
    );
  }

  /// Clears the mark of [mediaId] rows once the file was replaced by a new
  /// download, so the card stops warning about a file that is gone.
  static Future<void> clearForRecord(int recordId, int itemIndex) async {
    try {
      final db = await HistoryDb.instance();
      final record = (await db.recent(limit: 200))
          .where((r) => r.id == recordId)
          .firstOrNull;
      if (record == null) return;
      final updated = [
        for (final file in record.files)
          file.itemIndex == itemIndex && file.undecodable != null
              ? file.copyWith(undecodable: false)
              : file,
      ];
      await db.updateFiles(recordId, updated, source: 'decode-check-clear');
    } catch (_) {
      // Cosmetic only: the mark is re-derived by the next pass.
    }
  }
}
