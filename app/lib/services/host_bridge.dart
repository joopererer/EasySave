// Bridge from the native HostService to the running main UI (main isolate).
// The background engine cannot talk to the main engine directly, so it asks
// the native side to broadcast; MainActivity forwards it here.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

abstract final class HostBridge {
  static const MethodChannel _channel = MethodChannel('easysave/host');

  /// Bumped whenever the background engine has written history, so the history
  /// page can reload. Read by [HistoryPage] via a listener.
  static final ValueNotifier<int> historyRevision = ValueNotifier<int>(0);

  /// Register the handler once, from main().
  static void init() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'historyChanged') {
        historyRevision.value = historyRevision.value + 1;
      }
      return null;
    });
  }
}
