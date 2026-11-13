// The "下一次下载模拟失败" developer switch (v1.11 batch 2, moved into 开发者选项
// and made persistent in batch 4).
//
// The failure snapshot of v1.11 batch 1 could not be exercised on a real
// device: it only exists after a genuine failure, and producing one means
// breaking a file on purpose. This switch makes the next batch fail **once**,
// through the normal failure path (same message shape, same snapshot), after
// the download finished and before anything reaches the album.
//
// Rules, on purpose:
//   * only the **first file of the plan** of the next batch, and only once —
//     build 50 hit whichever file reached the import first (the second one),
//     which made the result depend on timing;
//   * a *final* failure: it is there to be seen, so nothing re-downloads the
//     file by itself. A manual retry clears it and downloads normally;
//   * nothing is written to the album and no other file is affected;
//   * the log line carries `simulated_failure=1` so a snapshot taken from it
//     cannot be mistaken for a real defect.
//
// Persistence (v1.11 batch 4): build 51 kept the flag in the main engine's
// memory only. A download started from the bubble or a share runs in the
// background engine, which never saw it, so no device log ever carried
// `simulated_failure`. The flag now lives in SharedPreferences, which both
// engines read (they share one file). It is still one-shot: the engine that
// consumes it clears the preference, so the other engine's next
// [refresh] sees it disarmed. It also survives an app restart and is only
// cleared by a trigger or by switching it off by hand.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DevDownloadFailure {
  DevDownloadFailure._();

  /// SharedPreferences key of the one-shot flag. Written by whichever engine
  /// armed or consumed it, read by both.
  static const String prefKey = 'devSimulatedDownloadFailureArmed';

  static bool _armed = false;
  static String? _batchId;

  /// Writes are queued so a read after an arm/disarm cannot see a stale value.
  static Future<void> _writes = Future<void>.value();

  /// Whether the switch is on (the UI shows this).
  static bool get armed => _armed;

  static void arm() {
    _armed = true;
    _batchId = null;
    _queueWrite(true);
  }

  static void disarm() {
    _armed = false;
    _batchId = null;
    _queueWrite(false);
  }

  /// Read the persisted flag again.
  ///
  /// Called by whichever engine is about to download: the switch can have been
  /// armed in the other engine, or consumed there, and this isolate's copy of
  /// the value would otherwise be the one from its own last use.
  static Future<void> refresh() async {
    await _writes;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final stored = prefs.getBool(prefKey) ?? false;
      _armed = stored;
      if (!stored) _batchId = null;
    } catch (_) {
      // Preferences unavailable (tests without a mock store): keep the
      // in-memory value, which is what the same engine armed.
    }
  }

  /// True exactly once, for the first file of the plan of the first batch after
  /// [arm]. [firstFile] is that file, not whichever one finishes first.
  static bool take(String batchId, {required bool firstFile}) {
    if (!_armed || !firstFile) return false;
    _batchId ??= batchId;
    if (batchId != _batchId) return false;
    _armed = false;
    // The other engine must see the switch used up, not still armed.
    _queueWrite(false);
    return true;
  }

  static void _queueWrite(bool value) {
    _writes = _writes.then((_) => _persist(value)).catchError((Object _) {});
  }

  static Future<void> _persist(bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (value) {
        await prefs.setBool(prefKey, true);
      } else {
        await prefs.remove(prefKey);
      }
    } catch (_) {
      // Preferences unavailable: the in-memory flag is all there is.
    }
  }

  /// Clears everything, including the stored flag (tests, and a fresh app).
  static void resetForTesting() {
    _armed = false;
    _batchId = null;
    _queueWrite(false);
  }

  /// Drops this isolate's copy of the state without touching the stored flag,
  /// which is what a *second* engine (a fresh isolate) starts with.
  @visibleForTesting
  static void forgetMemoryForTesting() {
    _armed = false;
    _batchId = null;
  }

  /// Lets a test wait for the queued preference writes to land.
  @visibleForTesting
  static Future<void> settleForTesting() => _writes;
}
