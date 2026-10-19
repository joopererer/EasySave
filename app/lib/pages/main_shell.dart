// Bottom-navigation shell: 解析 / 历史 / 我的.

import 'package:flutter/material.dart';

import '../services/download_manager.dart';
import '../services/host_bridge.dart';
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
  final _parseKey = GlobalKey<ParsePageState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    HostBridge.parseError.addListener(_consumeHostError);
    HostBridge.openRequest.addListener(_consumeHostOpen);
    // A cold-start error may already be present before the first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _consumeHostError();
      _consumeHostOpen();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    HostBridge.parseError.removeListener(_consumeHostError);
    HostBridge.openRequest.removeListener(_consumeHostOpen);
    super.dispose();
  }

  /// Show a background error on the parse tab, using the same error page as a
  /// manual parse. Consumed once.
  void _consumeHostError() {
    final err = HostBridge.parseError.value;
    if (err == null) return;
    HostBridge.parseError.value = null;
    _select(0);
    _parseKey.currentState?.showExternalError(err.url, err.code, err.message);
  }

  /// Open a url (e.g. the bubble's "打开 EasySave") on the parse tab.
  void _consumeHostOpen() {
    final url = HostBridge.openRequest.value;
    if (url == null || url.isEmpty) return;
    HostBridge.openRequest.value = null;
    _select(0);
    _parseKey.currentState?.showExternalUrl(url);
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
          ParsePage(key: _parseKey, onSeeAll: () => _select(1)),
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
