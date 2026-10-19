// Selection panel rendered by the SAME background engine (no third engine).
// HostService attaches a FlutterTextureView overlay to its engine; this widget
// tree is what the view shows. Normally the tree is empty; the background flow
// sets [selectPanelRequest] to present the grid.

import 'package:flutter/material.dart';

import '../core/models.dart';

class SelectPanelRequest {
  SelectPanelRequest({
    required this.post,
    required this.author,
    required this.onConfirm,
    required this.onCancel,
  });

  final ParsedPost post;
  final String author;
  final ValueChanged<List<int>> onConfirm;
  final VoidCallback onCancel;
}

/// Non-null while the selection panel should be shown.
final ValueNotifier<SelectPanelRequest?> selectPanelRequest =
    ValueNotifier<SelectPanelRequest?>(null);

/// Root widget of the background engine's view. Renders nothing until a
/// selection is requested.
class BackgroundRoot extends StatelessWidget {
  const BackgroundRoot({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: ValueListenableBuilder<SelectPanelRequest?>(
        valueListenable: selectPanelRequest,
        builder: (_, req, _) =>
            req == null ? const SizedBox.shrink() : SelectPanel(request: req),
      ),
    );
  }
}

class SelectPanel extends StatefulWidget {
  const SelectPanel({super.key, required this.request});

  final SelectPanelRequest request;

  @override
  State<SelectPanel> createState() => _SelectPanelState();
}

class _SelectPanelState extends State<SelectPanel> {
  late final Set<int> _selected;

  @override
  void initState() {
    super.initState();
    _selected = {
      for (var i = 0; i < widget.request.post.items.length; i++) i,
    };
  }

  void _toggle(int i) {
    setState(() {
      if (!_selected.remove(i)) _selected.add(i);
    });
  }

  void _toggleAll() {
    setState(() {
      if (_selected.length == widget.request.post.items.length) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll([
            for (var i = 0; i < widget.request.post.items.length; i++) i,
          ]);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.request.post.items;
    final total = items.length;
    final allSelected = _selected.length == total && total > 0;

    return Material(
      color: Colors.transparent,
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: widget.request.onCancel,
              child: Container(color: const Color(0x8A000000)),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              height: MediaQuery.of(context).size.height * 0.64,
              decoration: const BoxDecoration(
                color: Color(0xFF1C1B1A),
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              child: Column(
                children: [
                  const SizedBox(height: 10),
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                    child: Row(
                      children: [
                        const Text(
                          '选择要下载的内容',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '已选 ${_selected.length}/$total',
                          style: const TextStyle(color: Colors.white54, fontSize: 13),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: _toggleAll,
                          child: Text(
                            allSelected ? '取消全选' : '全选',
                            style: const TextStyle(color: Color(0xFFFF6A3D)),
                          ),
                        ),
                        IconButton(
                          onPressed: widget.request.onCancel,
                          icon: const Icon(Icons.close, color: Colors.white70),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: GridView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        mainAxisSpacing: 8,
                        crossAxisSpacing: 8,
                      ),
                      itemCount: total,
                      itemBuilder: (context, i) {
                        final item = items[i];
                        final thumb = item.posterUrl ?? item.url;
                        final selected = _selected.contains(i);
                        return GestureDetector(
                          onTap: () => _toggle(i),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                Container(color: const Color(0xFF2A2928)),
                                Image.network(
                                  thumb,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, _, _) => const Center(
                                    child: Icon(
                                      Icons.broken_image,
                                      color: Colors.white24,
                                    ),
                                  ),
                                ),
                                if (item.type == 'video')
                                  const Positioned(
                                    left: 6,
                                    bottom: 6,
                                    child: Icon(
                                      Icons.play_circle_fill,
                                      color: Colors.white,
                                      size: 20,
                                    ),
                                  ),
                                if (!selected)
                                  Container(color: const Color(0x99000000)),
                                Positioned(
                                  right: 6,
                                  top: 6,
                                  child: Container(
                                    width: 22,
                                    height: 22,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: selected
                                          ? const Color(0xFFFF5340)
                                          : const Color(0x66000000),
                                      border: Border.all(
                                        color: Colors.white,
                                        width: 1.5,
                                      ),
                                    ),
                                    child: selected
                                        ? const Icon(
                                            Icons.check,
                                            size: 15,
                                            color: Colors.white,
                                          )
                                        : null,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFFFF5340),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          onPressed: _selected.isEmpty
                              ? null
                              : () {
                                  final list = _selected.toList()..sort();
                                  widget.request.onConfirm(list);
                                },
                          child: Text('下载 (${_selected.length})'),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
