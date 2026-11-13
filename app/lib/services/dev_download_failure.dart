// The "下一次下载模拟失败" developer switch (v1.11 batch 2).
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
//   * in memory only, so an app restart always starts disarmed;
//   * the log line carries `simulated_failure=1` so a snapshot taken from it
//     cannot be mistaken for a real defect.
class DevDownloadFailure {
  DevDownloadFailure._();

  static bool _armed = false;
  static String? _batchId;
  static bool _consumed = false;

  /// Whether the switch is on (the UI shows this).
  static bool get armed => _armed;

  static void arm() {
    _armed = true;
    _batchId = null;
    _consumed = false;
  }

  static void disarm() {
    _armed = false;
    _batchId = null;
  }

  /// True exactly once, for the first file of the plan of the first batch after
  /// [arm]. [firstFile] is that file, not whichever one finishes first.
  static bool take(String batchId, {required bool firstFile}) {
    if (!_armed || _consumed || !firstFile) return false;
    _batchId ??= batchId;
    if (batchId != _batchId) return false;
    _consumed = true;
    _armed = false;
    return true;
  }

  /// Clears everything (tests).
  static void resetForTesting() {
    _armed = false;
    _batchId = null;
    _consumed = false;
  }
}
