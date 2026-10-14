// Preview page: 2-column grid, collapsible caption, ordered selection,
// fullscreen viewing, and saving through the download panel.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/models.dart';
import '../services/saver.dart';
import '../theme/app_theme.dart';
import '../widgets/download_sheet.dart';
import '../widgets/shared.dart';
import 'player_page.dart';

class PreviewPage extends StatefulWidget {
  const PreviewPage({super.key, required this.post, this.rawImages = const []});

  final ParsedPost post;
  final List<RawImageEntry> rawImages;

  @override
  State<PreviewPage> createState() => _PreviewPageState();
}

class _PreviewPageState extends State<PreviewPage> {
  late final List<int> _order = [
    for (var i = 0; i < widget.post.items.length; i++) i,
  ];

  bool get _selected => _order.isNotEmpty;

  String _badgeFor(MediaItem item) {
    if (item.type == 'video') {
      final duration = item.duration;
      if (duration != null && duration.isFinite) {
        final total = duration.round();
        final mm = (total ~/ 60).toString();
        final ss = (total % 60).toString().padLeft(2, '0');
        return '▶ $mm:$ss';
      }
      return '▶';
    }
    if (item.type == 'live') return 'Live';
    return '';
  }

  void _toggle(int index) {
    setState(() {
      if (_order.contains(index)) {
        _order.remove(index);
      } else {
        _order.add(index);
      }
    });
  }

  void _viewFullscreen(int index) {
    final item = widget.post.items[index];
    if (item.type == 'video') {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              VideoPlayerPage(item: item, platform: widget.post.platform),
        ),
      );
      return;
    }
    if (item.type == 'live' && item.videoUrl != null) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              LivePlayerPage(item: item, platform: widget.post.platform),
        ),
      );
      return;
    }
    showDialog<void>(
      context: context,
      builder: (context) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: Stack(
          children: [
            Center(
              child: InteractiveViewer(
                child: CoverImage(
                  key: ValueKey(item.url),
                  item: item,
                  referer: refererFor(widget.post.platform),
                  fit: BoxFit.contain,
                ),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (_order.isEmpty) return;
    // History is written by DownloadManager when the batch terminates
    // (including batches that finish while the app was killed).
    await DownloadSheet.show(context, widget.post, List.of(_order));
  }

  @override
  Widget build(BuildContext context) {
    final post = widget.post;
    final captionText = [
      if ((post.title ?? '').isNotEmpty) post.title!,
      if ((post.caption ?? '').isNotEmpty) post.caption!,
    ].join('\n\n');
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(child: Text(post.author.name ?? post.id)),
            const SizedBox(width: 8),
            PlatformTag(platform: post.platform),
          ],
        ),
      ),
      body: Column(
        children: [
          if (captionText.isNotEmpty)
            ExpansionTile(
              title: Text(
                post.title?.isNotEmpty == true ? post.title! : '查看文案',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(post.caption ?? ''),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('复制文案'),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: captionText));
                      if (context.mounted) {
                        ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(const SnackBar(content: Text('文案已复制')));
                      }
                    },
                  ),
                ),
              ],
            ),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
              ),
              itemCount: post.items.length,
              itemBuilder: (context, index) {
                final item = post.items[index];
                final badge = _badgeFor(item);
                final selectedIndex = _order.indexOf(index);
                final selected = selectedIndex >= 0;
                return GestureDetector(
                  onTap: () => _viewFullscreen(index),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: selected
                                ? AppTokens.primary
                                : Colors.transparent,
                            width: 3,
                          ),
                          borderRadius: const BorderRadius.all(
                            Radius.circular(AppTokens.thumbRadius),
                          ),
                        ),
                        // The image is clipped strictly inside the border
                        // ring (radius - border width) so square image
                        // corners can never punch through the rounded frame.
                        child: ClipRRect(
                          borderRadius: const BorderRadius.all(
                            Radius.circular(AppTokens.thumbRadius - 3),
                          ),
                          child: CoverImage(
                            key: ValueKey(item.url),
                            item: item,
                            referer: refererFor(post.platform),
                            cacheWidth: 400,
                          ),
                        ),
                      ),
                      if (item.type == 'video' || item.type == 'live')
                        const Center(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Colors.black45,
                              shape: BoxShape.circle,
                            ),
                            child: Padding(
                              padding: EdgeInsets.all(8),
                              child: Icon(
                                Icons.play_arrow,
                                color: Colors.white,
                                size: 28,
                              ),
                            ),
                          ),
                        ),
                      Positioned(
                        top: 6,
                        right: 6,
                        child: GestureDetector(
                          onTap: () => _toggle(index),
                          child: Container(
                            width: 28,
                            height: 28,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: selected
                                  ? AppTokens.primary
                                  : Colors.black45,
                            ),
                            alignment: Alignment.center,
                            child: selected
                                ? const Icon(
                                    Icons.check,
                                    color: Colors.white,
                                    size: 18,
                                  )
                                : null,
                          ),
                        ),
                      ),
                      if (badge.isNotEmpty)
                        Positioned(
                          left: 6,
                          bottom: 6,
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
                      if (selected)
                        Positioned(
                          right: 6,
                          bottom: 6,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: AppTokens.primary,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              '${selectedIndex + 1}/${_order.length}',
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
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: GradientButton(
              label: '保存到相册（${_order.length}）',
              onPressed: _selected ? _save : null,
            ),
          ),
        ],
      ),
    );
  }
}
