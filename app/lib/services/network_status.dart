// System connectivity for the download UI (v1.11 batch 2).
//
// Build 49 device report: in airplane mode a download stayed enqueued
// (`watchdog -> keepWaiting`) and the card kept spinning with no explanation;
// switching the network back on resumed it by itself. The resume is right, the
// silence is not.
//
// This is a **display-only** reading of the system connection state
// (ConnectivityManager: INTERNET + VALIDATED). Nothing in the download path
// consults it for control flow: queuing, retrying and resuming stay exactly as
// they were, so an offline batch still waits and still continues on its own.
// It exists so the progress area, the card overlay and the notification can
// say "等待网络…联网后自动继续" instead of an unexplained spinner.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class NetworkStatus extends ChangeNotifier {
  NetworkStatus._();

  static final NetworkStatus instance = NetworkStatus._();

  static const MethodChannel _channel = MethodChannel('easysave/connectivity');

  bool _online = true;
  bool _listening = false;
  bool _detached = false;

  /// Whether the system currently has a validated connection.
  bool get online => _online;

  /// Starts reading the system state. Call once from `main`.
  Future<void> start() async {
    if (_listening) return;
    _listening = true;
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'online') _apply(call.arguments == true);
      return null;
    });
    try {
      final online = await _channel.invokeMethod<bool>('isOnline');
      if (online != null && !_detached) _apply(online);
    } catch (_) {
      // No platform implementation (tests, desktop, older engine): stay
      // online, which is the pre-v1.11 display behaviour.
    }
  }

  void _apply(bool online) {
    if (_online == online) return;
    _online = online;
    notifyListeners();
  }

  /// Test seam: pretend the system reported [online].
  @visibleForTesting
  void setOnlineForTesting(bool online) => _apply(online);

  @visibleForTesting
  void resetForTesting() {
    _channel.setMethodCallHandler(null);
    _listening = false;
    _detached = false;
    _online = true;
  }

  /// Stops listening (the app is going away).
  void detach() {
    _detached = true;
    _listening = false;
    _channel.setMethodCallHandler(null);
  }
}
