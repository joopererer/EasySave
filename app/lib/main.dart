import 'dart:async';

import 'package:flutter/material.dart';

import 'pages/main_shell.dart';
import 'services/download_manager.dart';
import 'services/gallery_locator_service.dart';
import 'services/update_service.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Register background-download callbacks and recover batches that
  // finished while the app was dead.
  await DownloadManager.instance.init();
  await ParserManager.instance.init();
  unawaited(ParserManager.instance.checkForUpdates());
  runApp(const EasySaveApp());
  // Ask for album access up-front (first launch only) so the first history
  // view and "recent" thumbnails don't stall on a mid-flow permission prompt.
  unawaited(GalleryLocatorService.instance.ensurePermission());
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
