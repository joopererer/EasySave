// Tracks the real page stack so callers can ask "is the top page the preview
// of post X?" instead of keeping a separate flag that can drift.

import 'package:flutter/widgets.dart';

/// Route name given to every PreviewPage route. The post id travels in
/// `RouteSettings.arguments`.
const String kPreviewRouteName = '/preview';

/// NavigatorObserver that mirrors the stack of the navigator it is attached to.
class PreviewRouteObserver extends NavigatorObserver {
  PreviewRouteObserver();

  /// Shared instance attached to the app's MaterialApp.
  static final PreviewRouteObserver instance = PreviewRouteObserver();

  final List<Route<dynamic>> _stack = [];

  /// Number of routes currently tracked (for tests).
  int get depth => _stack.length;

  /// Drop everything tracked so far (tests only: the singleton outlives a
  /// single test case).
  @visibleForTesting
  void reset() => _stack.clear();

  /// Post id of the topmost page route when it is a preview page, else null.
  /// Popup routes (dialogs, bottom sheets, menus) are skipped: a sheet shown
  /// over a preview does not mean the user left it.
  String? get topPreviewPostId {
    for (final route in _stack.reversed) {
      if (route is PopupRoute) continue;
      if (route.settings.name != kPreviewRouteName) return null;
      final args = route.settings.arguments;
      return args is String ? args : null;
    }
    return null;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.add(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.remove(route);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.remove(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : _stack.indexOf(oldRoute);
    if (index >= 0) {
      if (newRoute != null) {
        _stack[index] = newRoute;
      } else {
        _stack.removeAt(index);
      }
    } else if (newRoute != null) {
      _stack.add(newRoute);
    }
  }
}
