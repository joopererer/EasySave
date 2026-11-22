// Copyright 2026 EasySave. All rights reserved.

import 'dart:async';
import 'package:flutter_test/flutter_test.dart';

/// Polls [condition] every [interval] until it returns true or a non-null value,
/// or until [timeout] is exceeded (defaults to 10 seconds, 20ms interval).
///
/// On timeout, fails the test and prints the current/last captured state.
Future<T> waitFor<T>(
  FutureOr<T?> Function() condition, {
  Duration timeout = const Duration(seconds: 10),
  Duration interval = const Duration(milliseconds: 20),
  dynamic Function()? currentState,
  String? description,
}) async {
  final stopwatch = Stopwatch()..start();
  dynamic lastValue;
  while (stopwatch.elapsed < timeout) {
    try {
      final res = await condition();
      if (res is bool) {
        if (res) return res as T;
      } else if (res != null) {
        return res;
      }
      lastValue = res;
    } catch (e) {
      lastValue = 'threw: $e';
    }
    await Future<void>.delayed(interval);
  }

  // Final check before failing
  try {
    final res = await condition();
    if (res is bool) {
      if (res) return res as T;
    } else if (res != null) {
      return res;
    }
    lastValue = res;
  } catch (e) {
    lastValue = 'threw: $e';
  }

  final stateDesc = currentState != null
      ? ' Current state: ${currentState()}'
      : ' Current state: $lastValue';
  fail(
    'waitFor timed out after ${timeout.inSeconds}s'
    '${description != null ? ' ($description)' : ''}.$stateDesc',
  );
}

