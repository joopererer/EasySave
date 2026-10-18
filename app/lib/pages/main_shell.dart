// Bottom-navigation shell: 解析 / 历史 / 我的.

import 'package:flutter/material.dart';

import '../services/download_manager.dart';
import 'history_page.dart';
import 'mine_page.dart';
import 'parse_page.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> with WidgetsBindingObserver {
  int _index = 0;
  bool _historySelectionMode = false;
  final _historyKey = GlobalKey<HistoryPageState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Pick up downloads that completed while the app was suspended.
    if (state == AppLifecycleState.resumed) {
      DownloadManager.instance.reconcile();
    }
  }

  void _select(int i) {
    setState(() => _index = i);
    if (i == 1) _historyKey.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          ParsePage(onSeeAll: () => _select(1)),
          HistoryPage(
            key: _historyKey,
            onGoParse: () => _select(0),
            onSelectionModeChanged: (active) {
              if (mounted) setState(() => _historySelectionMode = active);
            },
          ),
          const MinePage(),
        ],
      ),
      // Hide the nav bar while history multi-select is active; the history page
      // supplies its own share/delete action bar in that state.
      bottomNavigationBar: _historySelectionMode
          ? null
          : BottomNavigationBar(
              currentIndex: _index,
              onTap: _select,
              items: const [
                BottomNavigationBarItem(icon: Icon(Icons.search), label: '解析'),
                BottomNavigationBarItem(icon: Icon(Icons.history), label: '历史'),
                BottomNavigationBarItem(icon: Icon(Icons.person), label: '我的'),
              ],
            ),
    );
  }
}
