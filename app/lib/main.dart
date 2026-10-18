import 'dart:async';

import 'package:flutter/material.dart';

import 'background/background_entry.dart' as bg;
import 'pages/main_shell.dart';
import 'services/download_manager.dart';
import 'services/gallery_locator_service.dart';
import 'services/host_bridge.dart';
import 'services/update_service.dart';
import 'theme/app_theme.dart';

/// Entry point run by HostService's standalone FlutterEngine (no Activity),
/// for background parse + download triggered from the share / tile / bubble
/// entries.
@pragma('vm:entry-point')
void backgroundMain() {
  bg.backgroundEntry();
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Let the native HostService tell us when the background engine wrote
  // history, so the history page can refresh.
  HostBridge.init();
  // Register background-download callbacks and recover batches that
  // finished while the app was dead.
  await DownloadManager.instance.init();
  await ParserManager.instance.init();
  unawaited(ParserManager.instance.checkForUpdates());
  runApp(const EasySaveApp());
  // Ask for album access up-front (first launch only) so the first history
  // view and "recent" thumbnails don't stall on a mid-flow permission prompt.
  // Runs after the first frame so the activity is attached and the system
  // dialog can actually appear.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    GalleryLocatorService.instance.ensurePermission();
  });
}

class EasySaveApp extends StatelessWidget {
  const EasySaveApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'EasySave',
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      home: const MainShell(),
    );
  }
}
