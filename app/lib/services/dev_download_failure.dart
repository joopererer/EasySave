// The "下一次下载模拟失败" developer switch (v1.11 batch 2).
//
// The failure snapshot of v1.11 batch 1 could not be exercised on a real
// device: it only exists after a genuine failure, and producing one means
// breaking a file on purpose. This switch makes the next batch fail **once**,
// through the normal failure path (same message, same snapshot, same retry),
// after the download finished and before anything reaches the album.
//
// Rules, on purpose:
//   * only the first file of the next batch, and only once;
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

  /// True exactly once for the first file of the first batch after [arm].
  static bool take(String batchId) {
    if (!_armed || _consumed) return false;
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
