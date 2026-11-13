// Diagnostic counters for local thumbnails (v1.11).
//
// Build 48 report: on a real device every local thumbnail timed out after 5s
// (322 local_decode_failed lines) while DB reads and CDN covers were fine, and
// the log could not say which thumbnail, how long it waited or whether the
// system media service was stuck.
//
// This adds measurements only. Nothing here starts, retries, cancels or falls
// back anything: the widget keeps its own deadline and behaviour, and the
// counters are pure bookkeeping. The names say exactly what is measured:
//
//   * key                 the thumbnail identity (asset / kind / size);
//   * waited_ms           time from issuing the request to the result/timeout;
//   * inflight            local thumbnail requests issued, not yet resolved;
//   * concurrent_at_issue requests already unresolved when this one was
//                         issued, including itself — how crowded the queue was;
//   * oldest_ms           age of the oldest unresolved request;
//
// and the two reasons a wait can end badly:
//
//   * queue_timeout   the request was issued while other requests were already
//                     unresolved (concurrent_at_issue > 1), so it waited
//                     behind a backed-up native pipeline;
//   * system_timeout  the request was issued alone, so a single platform call
//                     never answered (a hung media service call).
//
// Build 49 (v1.11 batch 1) classified 625 timeouts as system_timeout while
// inflight peaked at 416: the old rule only looked at requests *still* open
// with a lower id at timeout time, and a whole flooded batch resolves in the
// same sweep, so each one after the first saw an almost empty set. The crowd
// is now recorded at issue time and cannot be washed away.
//
// Every 10 seconds — and once more when a burst goes idle, so a burst that
// lives shorter than the window is still summarised — one [ThumbStat] line
// reports the window.
//
// Why build 49 printed no summary on device: the periodic timer was cancelled
// as soon as nothing was in flight. On device a flooded batch was issued all
// at once and every request gave up at 5s, so the map went empty at 5s — 5s
// before the first 10s tick — and the timer died with it. The batch-1 tests
// missed it because they called `flushWindowForTesting()` directly instead of
// driving the timer. Both paths now share [_flushWindow]: the timer while
// something is in flight, and the idle transition when a burst ends.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/dev_log.dart';

/// One issued local-thumbnail request.
class ThumbnailRequest {
  ThumbnailRequest._(this.id, this.key, this.issuedAt, this.concurrentAtIssue);

  final int id;
  final String key;
  final DateTime issuedAt;

  /// Requests unresolved when this one was issued, including itself.
  final int concurrentAtIssue;

  bool get resolved => ThumbnailDiagnostics.instance._open[id] == null;
}

class ThumbnailDiagnostics {
  ThumbnailDiagnostics();

  static final ThumbnailDiagnostics instance = ThumbnailDiagnostics();

  /// Window of the summary line.
  static const Duration window = Duration(seconds: 10);

  final Map<int, ThumbnailRequest> _open = <int, ThumbnailRequest>{};
  int _nextId = 1;
  Timer? _timer;

  // Current window.
  int _ok = 0;
  int _decodeErrors = 0;
  int _queueTimeouts = 0;
  int _systemTimeouts = 0;
  int _totalMs = 0;
  int _completed = 0;
  int _maxMs = 0;
  int _maxInflight = 0;

  // Totals since the process started; the summary resets only the window.
  int _totalOk = 0;
  int _totalDecodeErrors = 0;
  int _totalQueueTimeouts = 0;
  int _totalSystemTimeouts = 0;

  int get inflight => _open.length;

  @visibleForTesting
  int get successes => _totalOk;
  @visibleForTesting
  int get queueTimeouts => _totalQueueTimeouts;
  @visibleForTesting
  int get systemTimeouts => _totalSystemTimeouts;
  @visibleForTesting
  int get decodeErrors => _totalDecodeErrors;

  /// Registers a request that is about to be issued.
  ThumbnailRequest begin(String key) {
    final request = ThumbnailRequest._(
      _nextId++,
      key,
      DateTime.now(),
      _open.length + 1,
    );
    _open[request.id] = request;
    if (_open.length > _maxInflight) _maxInflight = _open.length;
    _timer ??= Timer.periodic(window, (_) => _flushWindow());
    return request;
  }

  /// A frame arrived.
  void succeeded(ThumbnailRequest? request) {
    if (request == null) return;
    final elapsed = _resolve(request);
    if (elapsed == null) return;
    _ok++;
    _totalOk++;
    _account(elapsed, log: 'event=local_decode_ok');
    _afterChange();
  }

  /// The provider reported an error (a decode failure, not a timeout).
  void failed(ThumbnailRequest? request, {String reason = 'decode'}) {
    if (request == null) return;
    final elapsed = _resolve(request);
    if (elapsed == null) return;
    _decodeErrors++;
    _totalDecodeErrors++;
    _account(
      elapsed,
      log: 'event=local_decode_failed '
          'kind=${_kindOf(request.key)} reason=$reason key=${request.key}',
    );
    _afterChange();
  }

  /// The widget's own deadline expired before a frame arrived.
  ///
  /// [timeout] is the deadline that expired, used only to report how far over
  /// the request is when it finally gives up.
  void timedOut(ThumbnailRequest? request, {Duration? timeout}) {
    if (request == null) return;
    final now = DateTime.now();
    final older = _open.values.where((other) => other.id < request.id).length;
    var oldest = 0;
    for (final other in _open.values) {
      final age = now.difference(other.issuedAt).inMilliseconds;
      if (age > oldest) oldest = age;
    }
    // Queued means: this request was already waiting behind others the moment
    // it was issued. Requests of a flooded batch all time out in the same
    // sweep, so "is somebody else still open right now" cannot be the test.
    final queued = request.concurrentAtIssue > 1;
    final elapsed = _resolve(request);
    if (elapsed == null) return;

    if (queued) {
      _queueTimeouts++;
      _totalQueueTimeouts++;
    } else {
      _systemTimeouts++;
      _totalSystemTimeouts++;
    }
    _account(
      elapsed,
      log: 'event=local_decode_failed '
          'kind=${_kindOf(request.key)} '
          'reason=${queued ? 'queue_timeout' : 'system_timeout'} '
          'key=${request.key} '
          'timeout_ms=${timeout?.inMilliseconds ?? 0} '
          'older_unresolved=$older '
          'concurrent_at_issue=${request.concurrentAtIssue} '
          'oldest_unresolved_ms=$oldest',
    );
    _afterChange();
  }

  @visibleForTesting
  void resetForTesting() {
    _open.clear();
    _nextId = 1;
    _timer?.cancel();
    _timer = null;
    _ok = 0;
    _decodeErrors = 0;
    _queueTimeouts = 0;
    _systemTimeouts = 0;
    _totalMs = 0;
    _completed = 0;
    _maxMs = 0;
    _maxInflight = 0;
    _totalOk = 0;
    _totalDecodeErrors = 0;
    _totalQueueTimeouts = 0;
    _totalSystemTimeouts = 0;
  }

  /// Frees a request without recording an outcome (e.g. the card scrolled
  /// away or was rebuilt).
  void abandon(ThumbnailRequest? request) {
    if (request == null) return;
    if (_open.remove(request.id) != null) _afterChange();
  }

  Duration? _resolve(ThumbnailRequest request) {
    if (_open.remove(request.id) == null) return null;
    return DateTime.now().difference(request.issuedAt);
  }

  /// Keeps the periodic timer alive only while something is in flight, so the
  /// diagnostics never leave a timer behind (and never outlive the app's own
  /// idle state). A burst that ends before the window closes is summarised
  /// right here — that is the case build 49 dropped on the floor.
  void _afterChange() {
    if (_open.isNotEmpty) return;
    _flushWindow();
  }

  void _account(Duration elapsed, {required String log}) {
    final ms = elapsed.inMilliseconds;
    _totalMs += ms;
    _completed++;
    if (ms > _maxMs) _maxMs = ms;
    if (log.isNotEmpty) {
      unawaited(
        DevLog.write(
          'ThumbLoad',
          '$log waited_ms=$ms inflight=$inflight',
        ),
      );
    }
  }

  /// Emits the summary line and resets the window counters.
  void _flushWindow() {
    final idle = _open.isEmpty;
    if (_completed > 0 || !idle) {
      final average = _completed == 0 ? 0 : _totalMs ~/ _completed;
      unawaited(
        DevLog.write(
          'ThumbStat',
          'window_s=${window.inSeconds} ok=$_ok '
          'timeout=${_queueTimeouts + _systemTimeouts} '
          'queue=$_queueTimeouts system=$_systemTimeouts '
          'decode_fail=$_decodeErrors avg_ms=$average max_ms=$_maxMs '
          'max_inflight=$_maxInflight inflight=$inflight',
        ),
      );
      _ok = 0;
      _decodeErrors = 0;
      _queueTimeouts = 0;
      _systemTimeouts = 0;
      _totalMs = 0;
      _completed = 0;
      _maxMs = 0;
      _maxInflight = 0;
    }
    if (idle) {
      _timer?.cancel();
      _timer = null;
    }
  }

  static String _kindOf(String key) =>
      key.contains('/original/') ? 'original' : 'thumb';
}
