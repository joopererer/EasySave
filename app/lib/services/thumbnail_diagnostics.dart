// Diagnostic counters for local thumbnails (v1.11 batch 1).
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
//   * key            the thumbnail identity (asset / kind / size);
//   * waited_ms      time from issuing the request to the result or timeout;
//   * inflight       local thumbnail requests issued but not yet resolved;
//   * oldest_ms      age of the oldest unresolved request;
//
// and the two reasons a wait can end badly:
//
//   * queue_timeout  another request was still unresolved when this one hit
//                    its deadline, i.e. the native pipeline is backed up;
//   * system_timeout this request was alone, so a single platform call never
//                    answered (a hung media service call).
//
// Every 10 seconds the window is summarised in one line, so the moment the
// media service recovers is visible as a change from timeouts to successes.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/dev_log.dart';

/// One issued local-thumbnail request.
class ThumbnailRequest {
  ThumbnailRequest._(this.id, this.key, this.issuedAt);

  final int id;
  final String key;
  final DateTime issuedAt;

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

  int _ok = 0;
  int _decodeErrors = 0;
  int _queueTimeouts = 0;
  int _systemTimeouts = 0;
  int _totalMs = 0;
  int _completed = 0;
  int _maxMs = 0;

  int get inflight => _open.length;

  @visibleForTesting
  int get successes => _ok;
  @visibleForTesting
  int get queueTimeouts => _queueTimeouts;
  @visibleForTesting
  int get systemTimeouts => _systemTimeouts;
  @visibleForTesting
  int get decodeErrors => _decodeErrors;

  /// Registers a request that is about to be issued.
  ThumbnailRequest begin(String key) {
    final request = ThumbnailRequest._(_nextId++, key, DateTime.now());
    _open[request.id] = request;
    _timer ??= Timer.periodic(window, (_) => _flushWindow());
    return request;
  }

  /// A frame arrived.
  void succeeded(ThumbnailRequest? request) {
    if (request == null) return;
    final elapsed = _resolve(request);
    if (elapsed == null) return;
    _ok++;
    _account(elapsed, log: 'event=local_decode_ok');
    _afterChange();
  }

  /// The provider reported an error (a decode failure, not a timeout).
  void failed(ThumbnailRequest? request, {String reason = 'decode'}) {
    if (request == null) return;
    final elapsed = _resolve(request);
    if (elapsed == null) return;
    _decodeErrors++;
    _account(elapsed, log: 'event=local_decode_failed '
        'kind=${_kindOf(request.key)} reason=$reason key=${request.key}');
    _afterChange();
  }

  /// The widget's own deadline expired before a frame arrived.
  ///
  /// [timeout] is the deadline that expired, used only to report how far over
  /// the request is when it finally gives up.
  void timedOut(ThumbnailRequest? request, {Duration? timeout}) {
    if (request == null) return;
    final older = _open.values
        .where((other) => other.id < request.id)
        .map((other) => DateTime.now().difference(other.issuedAt))
        .toList();
    final oldest = _open.values.isEmpty
        ? 0
        : _open.values
              .map((other) => DateTime.now().difference(other.issuedAt).inMilliseconds)
              .reduce((a, b) => a > b ? a : b);
    final queued = older.isNotEmpty;
    final elapsed = _resolve(request);
    if (elapsed == null) return;

    if (queued) {
      _queueTimeouts++;
    } else {
      _systemTimeouts++;
    }
    _account(elapsed, log: 'event=local_decode_failed '
        'kind=${_kindOf(request.key)} '
        'reason=${queued ? 'queue_timeout' : 'system_timeout'} '
        'key=${request.key} '
        'timeout_ms=${timeout?.inMilliseconds ?? 0} '
        'older_unresolved=${older.length} '
        'oldest_unresolved_ms=$oldest');
    _afterChange();
  }

  /// Emits the summary line and resets the window counters.
  @visibleForTesting
  void flushWindowForTesting() => _flushWindow(force: true);

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
  /// idle state). Counters are kept for the next summary window.
  void _afterChange() {
    if (_open.isNotEmpty) return;
    _timer?.cancel();
    _timer = null;
  }

  void _account(Duration elapsed, {required String log}) {
    final ms = elapsed.inMilliseconds;
    _totalMs += ms;
    _completed++;
    if (ms > _maxMs) _maxMs = ms;
    if (log.isNotEmpty) {
      unawaited(DevLog.write('ThumbLoad', '$log waited_ms=$ms inflight=$inflight'));
    }
  }

  void _flushWindow({bool force = false}) {
    if (_completed == 0) {
      if (!force) return;
    }
    final average = _completed == 0 ? 0 : _totalMs ~/ _completed;
    unawaited(DevLog.write(
      'ThumbStat',
      'window_s=${window.inSeconds} ok=$_ok '
      'timeout=${_queueTimeouts + _systemTimeouts} '
      'queue=$_queueTimeouts system=$_systemTimeouts '
      'decode_fail=$_decodeErrors avg_ms=$average max_ms=$_maxMs '
      'inflight=$inflight',
    ));
    _ok = 0;
    _decodeErrors = 0;
    _queueTimeouts = 0;
    _systemTimeouts = 0;
    _totalMs = 0;
    _completed = 0;
    _maxMs = 0;
  }

  static String _kindOf(String key) =>
      key.contains('/original/') ? 'original' : 'thumb';
}
