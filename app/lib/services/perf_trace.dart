// Timing lines for the two interactions v1.11 batch 3 measures.
//
// `[ModeSwitch]` answers "what did switching 帖子 / 全部 / 创作者 cost?", and
// `[ViewerImage]` answers "how long until the viewer showed something, and how
// long until it showed everything?". Both are measurements only: they start a
// clock, watch what already happens and write one line. Nothing here issues,
// delays, retries or cancels a request, and nothing here changes what is drawn.
//
// Field meanings
// --------------
// ModeSwitch:
//   from / to        the view that was left and the one entered;
//   first_frame_ms   switch → the new view's first frame painted — "when it
//                    looked like it had switched";
//   visible_ready_ms switch → every local thumbnail request of the new view
//                    resolved (frame, failure or its own 5 s deadline) —
//                    "when the pictures were there";
//   cache_hit        visible thumbnails whose decoded image was already in the
//                    image cache (no native call needed);
//   cache_miss       visible thumbnails that had to issue a request;
//   local_requests   native thumbnail requests actually issued in the window
//                    (= cache_miss unless one is retried).
//
// ViewerImage:
//   index            the item's own index in the post;
//   source           local (album file) or remote (CDN);
//   placeholder_ms   viewer opened → the low-resolution placeholder painted;
//   full_ms          viewer opened → the full-resolution image painted. -1 when
//                    the full image never arrived (failure or timeout), -2 when
//                    the page was left before it did.
//
// A value of -1 in placeholder_ms means "no placeholder was shown", which is
// what the local stills of build 55 did.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/dev_log.dart';
import 'thumbnail_diagnostics.dart';

/// Writes one line. Tests replace it to collect lines instead of logging.
typedef PerfTraceSink = void Function(String tag, String message);

/// Entry point for the test seam.
abstract final class PerfTrace {
  /// When set, every probe created without an explicit sink writes here
  /// instead of to the device log. Set in tests, null in the app.
  @visibleForTesting
  static PerfTraceSink? sinkForTesting;
}

/// One switch of the history view, from its start until the visible thumbnails
/// of the new view have resolved.
///
/// [finish] is called by the probe itself; the owner only has to report the
/// first frame and — when the user switches again before the thumbnails settle —
/// [dispose] the old probe.
///
/// Build 55 device report: the line never appeared at all. The probe closed
/// only when *nothing in the whole app* was in flight, so one long-lived or
/// unrelated thumbnail request was enough to keep it open forever, and a second
/// switch dropped it silently. It now closes on the requests issued inside its
/// own window ([deadline] bounds the wait), and every switch that started
/// reports exactly one line.
class ModeSwitchProbe {
  ModeSwitchProbe({
    required this.from,
    required this.to,
    PerfTraceSink? sink,
    ThumbnailDiagnostics? diagnostics,
    this.deadline = const Duration(seconds: 10),
  }) : _sink = sink ?? _defaultSink,
       _diagnostics = diagnostics ?? ThumbnailDiagnostics.instance {
    _start = _diagnostics.counters;
    _watch.start();
    _diagnostics.addListener(_check);
    _timer = Timer(deadline, () {
      _finish(timedOut: true);
    });
  }

  final String from;
  final String to;
  final PerfTraceSink _sink;
  final ThumbnailDiagnostics _diagnostics;

  /// Longest the probe waits for its own thumbnails before reporting anyway.
  final Duration deadline;

  final Stopwatch _watch = Stopwatch();
  late final ThumbnailCounters _start;
  Timer? _timer;

  int? _firstFrameMs;
  bool _done = false;

  /// The new view's first frame is on screen.
  void firstFrame() {
    if (_done) return;
    _firstFrameMs ??= _watch.elapsedMilliseconds;
    _check();
  }

  void _check() {
    if (_done || _firstFrameMs == null) return;
    final delta = _diagnostics.counters - _start;
    // Only the switch's own window counts: every request issued after the
    // switch started has either finished or is still being waited for.
    if (delta.resolved < delta.issued) return;
    _finish();
  }

  void _finish({bool timedOut = false, bool superseded = false}) {
    if (_done) return;
    _done = true;
    _timer?.cancel();
    _diagnostics.removeListener(_check);
    final delta = _diagnostics.counters - _start;
    final settled = _firstFrameMs != null && delta.resolved >= delta.issued;
    if (!superseded) _watch.stop();
    _sink(
      'ModeSwitch',
      'from=$from to=$to first_frame_ms=${_firstFrameMs ?? -1} '
          'visible_ready_ms=${_watch.elapsedMilliseconds} '
          'cache_hit=${delta.hits} cache_miss=${delta.misses} '
          'local_requests=${delta.issued}'
          '${timedOut ? ' timed_out=1' : ''}'
          '${superseded ? ' superseded=1' : ''}'
          '${settled ? '' : ' settled=0'}',
    );
  }

  /// The user switched again before this one settled. The line is still
  /// written — the switch did happen, and how far it got is what the line says
  /// (`first_frame_ms=-1` when the new view never painted, `settled=0` when its
  /// thumbnails were still arriving) — because "one line per switch" is what
  /// makes the log measurable at all.
  void dispose() => _finish(superseded: true);
}

/// One still of the viewer: from opening the page to the full-resolution frame.
class ViewerImageProbe {
  ViewerImageProbe({
    required this.index,
    required this.source,
    PerfTraceSink? sink,
  }) : _sink = sink ?? _defaultSink {
    _watch.start();
  }

  /// The item's own index in the post.
  final int index;

  /// `local` (an album file) or `remote` (a CDN url).
  final String source;

  final PerfTraceSink _sink;
  final Stopwatch _watch = Stopwatch();

  int? _placeholderMs;
  bool _done = false;

  /// The low-resolution placeholder painted.
  void placeholderShown() {
    if (_done) return;
    _placeholderMs ??= _watch.elapsedMilliseconds;
  }

  /// The full-resolution image painted.
  void fullShown() {
    if (_done) return;
    _emit(_watch.elapsedMilliseconds);
  }

  /// The full image can no longer arrive (error, timeout, "not on this device").
  void failed() {
    if (_done) return;
    _emit(-1);
  }

  /// The page was left before the full image arrived.
  void dispose() {
    if (_done) return;
    _emit(-2);
  }

  void _emit(int fullMs) {
    _done = true;
    _watch.stop();
    _sink(
      'ViewerImage',
      'index=$index placeholder_ms=${_placeholderMs ?? -1} full_ms=$fullMs '
          'source=$source',
    );
  }
}

void _defaultSink(String tag, String message) {
  final seam = PerfTrace.sinkForTesting;
  if (seam != null) {
    seam(tag, message);
    return;
  }
  unawaited(DevLog.write(tag, message));
}
