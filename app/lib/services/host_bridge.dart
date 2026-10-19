// Bridge between the native HostService and the running main UI (main
// isolate). The background engine cannot talk to the main engine directly, so
// it asks the native side to broadcast/push; MainActivity forwards it here.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// An error reported by the background engine (shown on the same error page as
/// a manual parse).
class HostError {
  HostError({required this.url, required this.code, this.message});

  final String url;
  final String code;
  final String? message;

  static HostError? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final code = raw['code']?.toString();
    if (code == null || code.isEmpty) return null;
    return HostError(
      url: raw['url']?.toString() ?? '',
      code: code,
      message: raw['message']?.toString(),
    );
  }
}

abstract final class HostBridge {
  static const MethodChannel _channel = MethodChannel('easysave/host');

  /// Bumped whenever the background engine has written history, so the history
  /// page can reload.
  static final ValueNotifier<int> historyRevision = ValueNotifier<int>(0);

  /// Set when the background engine reports an error (or a tapped error
  /// notification opens the app). Consumed once by the shell.
  static final ValueNotifier<HostError?> parseError =
      ValueNotifier<HostError?>(null);

  /// Register the handler once, from main().
  static void init() {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'historyChanged':
          historyRevision.value = historyRevision.value + 1;
          break;
        case 'openParseError':
          parseError.value = HostError.fromMap(call.arguments);
          unawaited(_channel.invokeMethod<void>('clearPendingError'));
          break;
      }
      return null;
    });
  }

  /// Pull any error that was delivered before the Dart handler existed
  /// (cold start from a tapped error notification).
  static Future<void> pullPendingError() async {
    try {
      final raw = await _channel.invokeMethod<Object?>('getPendingError');
      final err = HostError.fromMap(raw);
      if (err != null) {
        parseError.value = err;
        await _channel.invokeMethod<void>('clearPendingError');
      }
    } catch (_) {
      // No pending error / channel unavailable.
    }
  }
}
