// One gate for every local image/video request.
//
// Build 22 added concurrency budgets and cross-engine single-flight for the
// *network* thumbnail path only; the local gallery path (photo_manager) had no
// budget, no timeout and no cancellation. photo_manager executes every call on a
// fixed 8-thread executor with an unbounded FIFO queue, so a handful of
// requests that never finish (a whole-file copy of a 1 GB video, a full-size
// original decode) stalls every thumbnail behind them until the process
// restarts.
//
// This gate gives each request class its own slots, a deadline of its own and a
// page-owned cancellation scope, and writes one `[MediaLoad]` line per
// lifecycle step so a device log names the request that is stuck:
//
//   [MediaLoad] id=8123 kind=cover source=thumbnailDataWithSize
//     event=completed pool=thumb waitMs=12 ioMs=48 ms=60
//     active=2/3 queued=5 abandoned=0
//
// Events: requested -> slotAcquired -> started -> completed | failed |
// timeout | cancelled. A timed-out or cancelled request releases its slot
// immediately, even though the underlying platform call cannot be aborted; its
// late result is dropped and counted as `abandoned`.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/dev_log.dart';

/// The reason a request exists; determines its pool and default deadline.
enum MediaLoadKind {
  /// A history/grid cover thumbnail.
  cover,

  /// A viewer thumbnail or strip thumbnail.
  thumb,

  /// A full-size local original (viewer image).
  original,

  /// Preparing a local video clip for playback.
  video,

  /// Preparing the motion part of a Live Photo.
  live,

  /// A MediaStore lookup that returns metadata, not pixels.
  lookup,
}

/// Independent budgets. A stuck original must never hold a thumbnail slot.
enum MediaLoadPool { lookup, thumb, original, video }

MediaLoadPool poolForKind(MediaLoadKind kind) => switch (kind) {
  MediaLoadKind.lookup => MediaLoadPool.lookup,
  MediaLoadKind.cover || MediaLoadKind.thumb => MediaLoadPool.thumb,
  MediaLoadKind.original => MediaLoadPool.original,
  MediaLoadKind.video || MediaLoadKind.live => MediaLoadPool.video,
};

/// A request ran out of time; its slot was released.
class MediaLoadTimeout implements Exception {
  const MediaLoadTimeout(this.kind, this.limit);
  final MediaLoadKind kind;
  final Duration limit;
  @override
  String toString() => 'MediaLoadTimeout(${kind.name}, ${limit.inMilliseconds}ms)';
}

/// The owning page or row was closed; the result was dropped.
class MediaLoadCancelled implements Exception {
  const MediaLoadCancelled(this.kind);
  final MediaLoadKind kind;
  @override
  String toString() => 'MediaLoadCancelled(${kind.name})';
}

/// Per-class deadlines. Thumbnails must appear fast, a video may take longer.
class MediaLoadLimits {
  MediaLoadLimits({
    this.cover = const Duration(seconds: 5),
    this.thumb = const Duration(seconds: 5),
    this.original = const Duration(seconds: 20),
    this.video = const Duration(seconds: 15),
    this.live = const Duration(seconds: 15),
    this.lookup = const Duration(seconds: 3),
  });

  Duration cover;
  Duration thumb;
  Duration original;
  Duration video;
  Duration live;
  Duration lookup;

  Duration of(MediaLoadKind kind) => switch (kind) {
    MediaLoadKind.cover => cover,
    MediaLoadKind.thumb => thumb,
    MediaLoadKind.original => original,
    MediaLoadKind.video => video,
    MediaLoadKind.live => live,
    MediaLoadKind.lookup => lookup,
  };

  /// A local original costs roughly one second per 10 MB on a phone; a 16 MB
  /// photo therefore gets ~9 s and a 1 GB clip the cap.
  Duration forBytes(int? bytes) {
    if (bytes == null || bytes <= 0) return original;
    final computed = Duration(
      milliseconds: 8000 + (bytes / (10 * 1024 * 1024)).ceil() * 1000,
    );
    return computed > const Duration(seconds: 90)
        ? const Duration(seconds: 90)
        : computed;
  }
}

/// Slots per pool. Thumbnails get the most and never share with originals.
class MediaLoadPoolSizes {
  const MediaLoadPoolSizes({
    this.lookup = 4,
    this.thumb = 3,
    this.original = 1,
    this.video = 1,
  });

  final int lookup;
  final int thumb;
  final int original;
  final int video;

  int of(MediaLoadPool pool) => switch (pool) {
    MediaLoadPool.lookup => lookup,
    MediaLoadPool.thumb => thumb,
    MediaLoadPool.original => original,
    MediaLoadPool.video => video,
  };
}

class _Waiter {
  _Waiter({required this.background});
  final bool background;
  final completer = Completer<bool>();
  bool granted = false;
  bool cancelledByScope = false;
  late _Pool pool;
}

class _Pool {
  _Pool(this.name, this.limit);
  final String name;
  int limit;
  int active = 0;
  int abandoned = 0;
  final _foreground = <_Waiter>[];
  final _background = <_Waiter>[];

  int get queued => _foreground.length + _background.length;

  bool get hasFree => active < limit;

  void _enqueue(_Waiter waiter) {
    waiter.pool = this;
    (waiter.background ? _background : _foreground).add(waiter);
  }

  void _remove(_Waiter waiter) {
    _foreground.remove(waiter);
    _background.remove(waiter);
  }

  /// A completed request hands its slot straight to the next waiter: cover
  /// requests first, speculative pre-decodes last.
  void onSlotDone() {
    if (_foreground.isNotEmpty) {
      final next = _foreground.removeAt(0)..granted = true;
      next.completer.complete(true);
      return;
    }
    if (_background.isNotEmpty) {
      final next = _background.removeAt(0)..granted = true;
      next.completer.complete(true);
      return;
    }
    if (active > 0) active--;
  }

  void forgetAbandoned() {
    abandoned++;
  }
}

class _Slot {
  _Slot(this.pool);
  final _Pool pool;
  bool released = false;

  void release({bool abandoned = false}) {
    if (released) return;
    released = true;
    if (abandoned) pool.forgetAbandoned();
    pool.onSlotDone();
  }
}

/// Cancels every request a page or a row started when it goes away.
class MediaLoadScope {
  MediaLoadScope([String? name]) : name = name ?? 'scope';
  final String name;
  final _waiters = <_Waiter>{};
  final _runners = <void Function()>{};
  bool _disposed = false;

  bool get isDisposed => _disposed;

  void _watch(_Waiter waiter) => _waiters.add(waiter);
  void _unwatch(_Waiter waiter) => _waiters.remove(waiter);
  void _watchRun(void Function() cancel) => _runners.add(cancel);
  void _unwatchRun(void Function() cancel) => _runners.remove(cancel);

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final waiter in _waiters.toList()) {
      // A granted waiter already holds a slot, which only the run() that owns
      // it can release; disposing it here would leak the slot.
      if (waiter.granted) continue;
      waiter.cancelledByScope = true;
      if (!waiter.completer.isCompleted) waiter.completer.complete(false);
    }
    _waiters.clear();
    for (final cancel in _runners.toList()) {
      cancel();
    }
    _runners.clear();
  }
}

/// Accepts requests, enforces pools/deadlines, writes the `[MediaLoad]` trail.
abstract final class MediaLoadGate {
  static MediaLoadLimits limits = MediaLoadLimits();
  static MediaLoadPoolSizes sizes = const MediaLoadPoolSizes();

  static final Map<MediaLoadPool, _Pool> _pools = {
    for (final pool in MediaLoadPool.values)
      pool: _Pool(pool.name, const MediaLoadPoolSizes().of(pool)),
  };

  static _Pool _pool(MediaLoadPool pool) {
    final existing = _pools[pool]!;
    if (existing.limit != sizes.of(pool)) {
      existing.limit = sizes.of(pool);
    }
    return existing;
  }

  /// `lookup=1/4q0 thumb=3/3q7 original=1/1q2 video=0/1q0`
  static String get poolSnapshot => [
    for (final pool in MediaLoadPool.values)
      '${pool.name}=${_pool(pool).active}/${_pool(pool).limit}'
          'q${_pool(pool).queued}',
  ].join(' ');

  @visibleForTesting
  static void resetForTesting() {
    limits = MediaLoadLimits();
    sizes = const MediaLoadPoolSizes();
    _pools.clear();
    for (final pool in MediaLoadPool.values) {
      _pools[pool] = _Pool(pool.name, sizes.of(pool));
    }
  }

  @visibleForTesting
  static ({int active, int queued, int abandoned}) snapshot(MediaLoadPool pool) {
    final p = _pool(pool);
    return (active: p.active, queued: p.queued, abandoned: p.abandoned);
  }

  static void _log(
    String event, {
    required String id,
    required MediaLoadKind kind,
    required String source,
    required _Pool pool,
    int? waitMs,
    int? ioMs,
    int? ms,
    String extra = '',
  }) {
    DevLog.write(
      'MediaLoad',
      'id=$id kind=${kind.name} source=$source event=$event pool=${pool.name}'
      ' waitMs=${waitMs ?? 0} ioMs=${ioMs ?? 0} ms=${ms ?? 0}'
      ' active=${pool.active}/${pool.limit} queued=${pool.queued}'
      ' abandoned=${pool.abandoned}'
      '${extra.isEmpty ? '' : ' $extra'} pools=[$poolSnapshot]',
    );
  }

  /// Run [action] inside the slot budget of [kind].
  ///
  /// The deadline covers queueing *and* the action. When it expires (or [scope]
  /// is disposed) the slot is released at once, the caller gets
  /// [MediaLoadTimeout] / [MediaLoadCancelled], and a late result is dropped.
  static Future<T> run<T>({
    required MediaLoadKind kind,
    required String id,
    required String source,
    required Future<T> Function() action,
    Duration? timeout,
    MediaLoadScope? scope,
    bool background = false,
    String extra = '',
  }) async {
    final pool = _pool(poolForKind(kind));
    final limit = timeout ?? limits.of(kind);
    final start = Stopwatch()..start();
    void log(String event, {int? ioMs, int? ms, String more = ''}) => _log(
      event,
      id: id,
      kind: kind,
      source: source,
      pool: pool,
      waitMs: start.elapsedMilliseconds,
      ioMs: ioMs,
      ms: ms,
      extra: more,
    );

    if (scope?.isDisposed == true) {
      _log('cancelled',
          id: id, kind: kind, source: source, pool: pool,
          extra: 'phase=queue reason=scope_disposed');
      throw MediaLoadCancelled(kind);
    }
    log('requested', more: extra);

    _Slot slot;
    if (pool.hasFree) {
      pool.active++;
      slot = _Slot(pool);
    } else {
      final waiter = _Waiter(background: background);
      pool._enqueue(waiter);
      scope?._watch(waiter);
      log('queued');
      var granted = false;
      try {
        granted = await waiter.completer.future.timeout(limit, onTimeout: () {
          pool._remove(waiter);
          return false;
        });
      } finally {
        scope?._unwatch(waiter);
      }
      if (!granted) {
        pool._remove(waiter);
        if (waiter.cancelledByScope) {
          _log('cancelled',
              id: id, kind: kind, source: source, pool: pool,
              extra: 'phase=queue reason=scope_disposed');
          throw MediaLoadCancelled(kind);
        }
        _log('timeout',
            id: id, kind: kind, source: source, pool: pool,
            extra: 'phase=queue limitMs=${limit.inMilliseconds}');
        throw MediaLoadTimeout(kind, limit);
      }
      slot = _Slot(pool);
      log('slotAcquired');
    }

    final remaining = limit - start.elapsed;
    if (remaining <= Duration.zero) {
      slot.release();
      _log('timeout',
          id: id, kind: kind, source: source, pool: pool,
          extra: 'phase=queue limitMs=${limit.inMilliseconds}');
      throw MediaLoadTimeout(kind, limit);
    }

    log('started', more: 'limitMs=${limit.inMilliseconds}');
    final io = Stopwatch()..start();
    final done = Completer<T>();
    var settled = false;
    Timer? timer;
    void Function()? cancelRun;

    void detach() {
      timer?.cancel();
      final run = cancelRun;
      if (run != null) scope?._unwatchRun(run);
      cancelRun = null;
    }

    void succeed(T value) {
      if (settled) return;
      settled = true;
      detach();
      slot.release();
      _log('completed',
          id: id, kind: kind, source: source, pool: pool,
          ioMs: io.elapsedMilliseconds, ms: start.elapsedMilliseconds);
      done.complete(value);
    }

    void fail(Object error, StackTrace stack) {
      if (settled) return;
      settled = true;
      detach();
      slot.release();
      _log('failed',
          id: id, kind: kind, source: source, pool: pool,
          ioMs: io.elapsedMilliseconds, ms: start.elapsedMilliseconds,
          extra: 'error=${error.runtimeType}');
      done.completeError(error, stack);
    }

    /// The caller stops waiting. The platform call cannot be aborted, so the
    /// slot is returned now and the late result is dropped.
    void abandon(String reason) {
      if (settled) return;
      settled = true;
      detach();
      slot.release(abandoned: true);
      _log(reason == 'timeout' ? 'timeout' : 'cancelled',
          id: id, kind: kind, source: source, pool: pool,
          ioMs: io.elapsedMilliseconds, ms: start.elapsedMilliseconds,
          extra: 'phase=run limitMs=${limit.inMilliseconds}');
      done.completeError(
        reason == 'timeout' ? MediaLoadTimeout(kind, limit) : MediaLoadCancelled(kind),
      );
    }

    timer = Timer(remaining, () => abandon('timeout'));
    if (scope != null) {
      cancelRun = () => abandon('cancelled');
      scope._watchRun(cancelRun!);
    }

    final Future<T> actionFuture;
    try {
      actionFuture = action();
    } catch (error, stack) {
      fail(error, stack);
      return done.future;
    }
    unawaited(actionFuture.then(succeed, onError: fail));
    return done.future;
  }

  /// Log a request whose concurrency is owned elsewhere (network downloads,
  /// native channel calls) so one log stream covers every media request.
  static Future<T> trace<T>({
    required MediaLoadKind kind,
    required String id,
    required String source,
    required Future<T> Function() action,
    String extra = '',
  }) async {
    final pool = _pool(poolForKind(kind));
    final start = Stopwatch()..start();
    _log('requested', id: id, kind: kind, source: source, pool: pool,
        extra: extra);
    try {
      final value = await action();
      _log('completed', id: id, kind: kind, source: source, pool: pool,
          ioMs: start.elapsedMilliseconds, ms: start.elapsedMilliseconds);
      return value;
    } on MediaLoadTimeout catch (timeout) {
      _log('timeout', id: id, kind: kind, source: source, pool: pool,
          ioMs: start.elapsedMilliseconds, ms: start.elapsedMilliseconds,
          extra: 'limitMs=${timeout.limit.inMilliseconds}');
      rethrow;
    } catch (error) {
      _log('failed', id: id, kind: kind, source: source, pool: pool,
          ioMs: start.elapsedMilliseconds, ms: start.elapsedMilliseconds,
          extra: 'error=${error.runtimeType}');
      rethrow;
    }
  }
}
