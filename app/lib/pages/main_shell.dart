// Bottom-navigation shell: 解析 / 历史 / 我的.

import 'package:flutter/material.dart';

import 'history_page.dart';
import 'mine_page.dart';
import 'parse_page.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = 0;
  final _historyKey = GlobalKey<HistoryPageState>();

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
          HistoryPage(key: _historyKey, onGoParse: () => _select(0)),
          const MinePage(),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
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
