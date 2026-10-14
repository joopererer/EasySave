import 'package:flutter/material.dart';

import 'pages/main_shell.dart';
import 'services/download_manager.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Register background-download callbacks and recover batches that
  // finished while the app was dead.
  await DownloadManager.instance.init();
  runApp(const EasySaveApp());
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
