// Floating bubble control (Android overlay). The bubble itself is native
// (OverlayService); here we only start/stop it and query the overlay
// permission.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'settings.dart';

abstract final class BubbleService {
  static const MethodChannel _channel = MethodChannel('easysave/bubble');

  /// Bumped whenever native reports a bubble state change (e.g. the bubble was
  /// dragged to the close zone). Mine page listens and reconciles the toggle.
  static final ValueNotifier<int> stateTick = ValueNotifier<int>(0);
  static bool _listening = false;

  /// Receive native -> Dart state pushes on the shared bubble channel.
  static void startListening() {
    if (_listening) return;
    _listening = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'bubbleStateChanged') {
        stateTick.value = stateTick.value + 1;
      }
      return null;
    });
  }

  /// Whether the "display over other apps" permission is granted.
  static Future<bool> hasPermission() async {
    try {
      return await _channel.invokeMethod<bool>('hasPermission') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Open the system overlay-permission settings.
  static Future<void> requestPermission() async {
    try {
      await _channel.invokeMethod<void>('requestPermission');
    } catch (_) {}
  }

  /// Start the bubble; returns false when the permission is missing.
  static Future<bool> start() async {
    try {
      return await _channel.invokeMethod<bool>('start') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {}
  }

  static Future<bool> isRunning() async {
    try {
      return await _channel.invokeMethod<bool>('isRunning') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Open the app's system settings page (for enabling autostart / background).
  static Future<void> openAppSettings() async {
    try {
      await _channel.invokeMethod<void>('openAppSettings');
    } catch (_) {}
  }

  /// Push auto-hide preference change to the running bubble overlay service.
  static Future<void> updateAutoHide(bool enabled) async {
    try {
      await _channel.invokeMethod<void>('updateAutoHide', {'enabled': enabled});
    } catch (_) {}
  }

  /// At app start: ensure the bubble is running when it's enabled and granted.
  /// If permission was revoked, syncs the setting switch to false.
  static Future<void> ensureStarted() async {
    final settings = await AppSettings.load();
    if (!settings.bubbleEnabled) return;
    final granted = await hasPermission();
    if (!granted) {
      settings.bubbleEnabled = false;
      await settings.save();
      stateTick.value = stateTick.value + 1;
      return;
    }
    if (!await isRunning()) {
      await start();
    }
  }
}
