// Preview page: thumbnail grid with per-item selection and album saving.

import 'package:flutter/material.dart';

import '../core/models.dart';
import '../services/saver.dart';

class PreviewPage extends StatefulWidget {
  const PreviewPage({super.key, required this.post, this.rawImages = const []});

  final ParsedPost post;
  final List<RawImageEntry> rawImages;

  @override
  State<PreviewPage> createState() => _PreviewPageState();
}

class _PreviewPageState extends State<PreviewPage> {
  late final Set<int> _selected = {
    for (var i = 0; i < widget.post.items.length; i++) i,
  };
  bool _saving = false;
  String _status = '';

  String _badgeFor(MediaItem item) {
    if (item.type == 'video') return '视频';
    if (item.type == 'live') return '实况';
    return '';
  }

  Future<void> _save() async {
    if (_selected.isEmpty || _saving) return;
    setState(() {
      _saving = true;
      _status = '准备保存…';
    });
    try {
      final order = _selected.toList()..sort();
      await saveItems(widget.post, order, (progress) async {
        if (!mounted) return;
        setState(() {
          _status = '正在保存 ${progress.done}/${progress.total}…';
        });
      });
      if (!mounted) return;
      setState(() => _status = '已保存到相册 EasySave');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = '保存失败：$e';
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final post = widget.post;
    return Scaffold(
      appBar: AppBar(title: Text(post.author.name ?? post.id)),
      body: Column(
        children: [
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.all(8),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
              ),
              itemCount: post.items.length,
              itemBuilder: (context, index) {
                final item = post.items[index];
                final badge = _badgeFor(item);
                final selected = _selected.contains(index);
                return GestureDetector(
                  onTap: () => setState(() {
                    if (selected) {
                      _selected.remove(index);
                    } else {
                      _selected.add(index);
                    }
                  }),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: selected ? Colors.red : Colors.transparent,
                            width: 3,
                          ),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: _Thumb(key: ValueKey(item.url), item: item),
                      ),
                      Positioned(
                        top: 4,
                        right: 4,
                        child: Icon(
                          selected ? Icons.check_circle : Icons.circle_outlined,
                          color: selected ? Colors.red : Colors.white,
                        ),
                      ),
                      if (badge.isNotEmpty)
                        Positioned(
                          left: 4,
                          bottom: 4,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              badge,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
          if (_status.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(_status, style: const TextStyle(fontSize: 13)),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _saving || _selected.isEmpty ? null : _save,
                child: Text(_saving ? '保存中…' : '保存到相册（${_selected.length}）'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Thumbnail that walks through the primary URL and its fallbacks before
/// showing the broken-image placeholder.
class _Thumb extends StatefulWidget {
  const _Thumb({super.key, required this.item});

  final MediaItem item;

  @override
  State<_Thumb> createState() => _ThumbState();
}

class _ThumbState extends State<_Thumb> {
  int _attempt = 0;

  @override
  Widget build(BuildContext context) {
    // Display order: CDN originals first. The rewritten ci.xiaohongshu.com
    // primary is occasionally slow/unreachable from mobile networks (the
    // 0/2/6 pattern); it stays in the rotation as a fallback.
    final urls = [...widget.item.fallbacks, widget.item.url];
    return Image.network(
      urls[_attempt.clamp(0, urls.length - 1)],
      fit: BoxFit.cover,
      // Thumbnails only need grid resolution; asking for the multi-MB
      // original for a ~120px cell is what made the grid feel slow.
      cacheWidth: 400,
      errorBuilder: (context, error, stackTrace) {
        if (_attempt + 1 < urls.length) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _attempt++);
          });
          return const ColoredBox(color: Colors.black12);
        }
        return const ColoredBox(
          color: Colors.black12,
          child: Icon(Icons.broken_image),
        );
      },
    );
  }
}
