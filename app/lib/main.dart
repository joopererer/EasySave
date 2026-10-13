import 'package:flutter/material.dart';

import 'pages/main_shell.dart';
import 'theme/app_theme.dart';

void main() {
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
