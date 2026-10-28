import 'dart:async';
import '../core/dev_log.dart';

class HistoryRefreshCancelled implements Exception {}

/// Page-owned deadlines are cancelled on disposal, even if native I/O hangs.
class HistoryDeadline {
  final _cancel = <void Function()>{};
  bool _disposed = false;
  bool get isDisposed => _disposed;
  Future<T> wait<T>(Future<T> source, Duration timeout) {
    if (_disposed) return Future.error(HistoryRefreshCancelled());
    final done = Completer<T>();
    late Timer timer;
    void cancel() {
      timer.cancel();
      if (!done.isCompleted) done.completeError(HistoryRefreshCancelled());
    }

    timer = Timer(timeout, () {
      if (!done.isCompleted)
        done.completeError(TimeoutException('history step'));
    });
    _cancel.add(cancel);
    source.then(
      (value) {
        if (!done.isCompleted) done.complete(value);
      },
      onError: (Object error, StackTrace stack) {
        if (!done.isCompleted) done.completeError(error, stack);
      },
    );
    return done.future.whenComplete(() {
      timer.cancel();
      _cancel.remove(cancel);
    });
  }

  void dispose() {
    _disposed = true;
    for (final cancel in _cancel.toList()) {
      cancel();
    }
    _cancel.clear();
  }
}

/// Timing diagnostics contain only a step name and elapsed milliseconds.
Future<T> historyStep<T>(
  String step,
  Future<T> Function() action, {
  Duration timeout = const Duration(seconds: 5),
  HistoryDeadline? deadline,
}) async {
  final watch = Stopwatch()..start();
  var completed = false;
  try {
    if (deadline?.isDisposed == true) throw HistoryRefreshCancelled();
    final source = action();
    final result = await (deadline == null
        ? source.timeout(timeout)
        : deadline.wait(source, timeout));
    completed = true;
    return result;
  } finally {
    DevLog.write(
      'HistoryTiming',
      'step=$step${completed ? "" : "-failed"} ms=${watch.elapsedMilliseconds}',
    );
  }
}

final _background = <Future<void>>{};
Future<void> historyBackground(
  String step,
  Future<void> Function() action, {
  Duration timeout = const Duration(seconds: 2),
  HistoryDeadline? deadline,
}) {
  final work = historyStep(
    step,
    action,
    timeout: timeout,
    deadline: deadline,
  ).catchError((Object _) {});
  _background.add(work);
  unawaited(work.whenComplete(() => _background.remove(work)));
  return work;
}

/// Allows regression tests to await bounded background work without changing
/// the user-facing deletion/refresh completion boundary.
Future<void> historyBackgroundSettled() async {
  while (_background.isNotEmpty) {
    await Future.wait(_background.toList());
  }
}

class HistoryRefreshController {
  HistoryRefreshController({this.mediaTimeout = const Duration(seconds: 5)});
  final Duration mediaTimeout;
  final deadline = HistoryDeadline();
  void dispose() => deadline.dispose();
  Future<void>? _load;
  Future<void>? _media;
  Future<void> refresh(
    Future<void> Function() load,
    Future<void> Function() media,
  ) {
    return _load ??= (() async {
      try {
        await historyStep('refresh-records', load, deadline: deadline);
        if (_media == null) {
          final work = historyBackground(
            'refresh-media',
            media,
            timeout: mediaTimeout,
            deadline: deadline,
          );
          _media = work;
          unawaited(work.whenComplete(() => _media = null));
        }
      } on HistoryRefreshCancelled {
        // A late native result must not keep a disposed page alive.
      } finally {
        _load = null;
      }
    })();
  }
}
