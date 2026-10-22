// Preview page: 2-column grid, collapsible caption, ordered selection,
// fullscreen viewing, and saving through the download panel.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/dev_log.dart';
import '../core/models.dart';
import '../services/download_manager.dart';
import '../services/gallery_locator_service.dart';
import '../services/history_db.dart';
import '../services/host_bridge.dart';
import '../services/preview_route_observer.dart';
import '../services/saver.dart';
import '../theme/app_theme.dart';
import '../widgets/download_sheet.dart';
import '../widgets/gallery_browser.dart';
import '../widgets/shared.dart';

class PreviewPage extends StatefulWidget {
  const PreviewPage({
    super.key,
    required this.post,
    this.rawImages = const [],
    this.onSaved,
  });

  final ParsedPost post;
  final List<RawImageEntry> rawImages;

  /// Called once a save (or local association) succeeds, so the caller can
  /// clear the paste box.
  final VoidCallback? onSaved;

  /// Rebuild a post from a stored history record (shared by the history
  /// list and the home "recent" cards).
  static ParsedPost postFromRecord(HistoryRecord record) => record.toPost();

  /// The only way preview pages should be pushed: the route carries a name
  /// and the post id so [PreviewRouteObserver] can tell from the real page
  /// stack which post's preview is on screen.
  static Route<void> route({
    required ParsedPost post,
    List<RawImageEntry> rawImages = const [],
    VoidCallback? onSaved,
  }) {
    return MaterialPageRoute<void>(
      settings: RouteSettings(name: kPreviewRouteName, arguments: post.id),
      builder: (_) =>
          PreviewPage(post: post, rawImages: rawImages, onSaved: onSaved),
    );
  }

  @override
  State<PreviewPage> createState() => _PreviewPageState();
}

class _PreviewPageState extends State<PreviewPage> {
  late final List<int> _order = [
    for (var i = 0; i < widget.post.items.length; i++) i,
  ];
  Set<int> _downloaded = {};
  // Thumbnails only start fetching after the push transition settles:
  // firing N concurrent original-size downloads inside the animation
  // starves the raster thread and freezes the transition mid-way.
  bool _imagesReady = false;

  @override
  void initState() {
    super.initState();
    _checkDownloaded();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(milliseconds: 350), () {
        if (mounted) setState(() => _imagesReady = true);
      });
    });
  }

  Future<void> _checkDownloaded() async {
    final downloaded =
        await GalleryLocatorService.instance.findDownloadedIndices(widget.post);
    if (!mounted) return;
    setState(() {
      _downloaded = downloaded;
    });
  }

  bool get _selected => _order.isNotEmpty;

  String _badgeFor(MediaItem item) {
    if (item.type == 'video') {
      if (item.isGif == true) return 'GIF';
      final duration = item.duration;
      if (duration != null && duration.isFinite) {
        final total = duration.round();
        final mm = (total ~/ 60).toString();
        final ss = (total % 60).toString().padLeft(2, '0');
        return '▶ $mm:$ss';
      }
      return '▶';
    }
    if (item.type == 'live') return 'LIVE';
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

  void _viewFullscreen(int index) async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => GalleryBrowserPage(
          items: [
            for (var i = 0; i < widget.post.items.length; i++)
              GalleryBrowserItem(
                index: i,
                type: widget.post.items[i].type,
                url: widget.post.items[i].url,
                videoUrl: widget.post.items[i].videoUrl,
                posterUrl: widget.post.items[i].posterUrl,
                fallbacks: widget.post.items[i].fallbacks,
                isGif: widget.post.items[i].isGif ?? false,
                status: FileStatus.found,
              ),
          ],
          initialIndex: index,
          authorName: widget.post.author.name ?? '',
          title: widget.post.title ?? widget.post.id,
          platform: widget.post.platform,
          postUrl: widget.post.url,
          showSave: true,
          selectedIndices: _order.toSet(),
          onSelectionChanged: (set) {
            setState(() {
              _order.removeWhere((i) => !set.contains(i));
              for (final i in set) {
                if (!_order.contains(i)) _order.add(i);
              }
            });
          },
        ),
      ),
    );
    // The viewer's 保存 button closes with true: start the save from here.
    if (result == true && mounted) {
      await _save();
    }
  }

  Future<void> _save() async {
    if (_order.isEmpty) return;
    final locator = GalleryLocatorService.instance;
    // Re-check which selected items are already in the album right before
    // saving: those are associated with the history record instead of being
    // downloaded again. The album scan happens once and the result is reused
    // for the association write, so the two steps cannot disagree.
    final matches = await locator.matchPostItems(widget.post);
    final downloaded = matches.keys.toSet();
    final toAssociate = _order.where(downloaded.contains).toList();
    final toDownload = _order.where((i) => !downloaded.contains(i)).toList();
    if (!mounted) return;

    DevLog.write(
      'V16DL', // i18n:ignore 日志
      'save plan post=${widget.post.id} selected=${_order.length} '
      'associate=${toAssociate.length} download=${toDownload.length}',
    );

    var associated = 0;
    if (toAssociate.isNotEmpty) {
      associated = await locator.associateExisting(
        widget.post,
        toAssociate,
        // The user pressed "保存": the post must be back in the history, even
        // if they had deleted the record before.
        restoreDeleted: true,
        matches: matches,
      );
    }
    if (!mounted) return;

    // Everything was already local: just link the records and go back.
    if (toDownload.isEmpty) {
      widget.onSaved?.call();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已将 $associated 个本地文件关联到历史记录')),
      );
      // Notify history page to refresh
      HostBridge.historyRevision.value = HostBridge.historyRevision.value + 1;
      Navigator.of(context).pop(true);
      return;
    }

    final batch = await DownloadSheet.show(context, widget.post, toDownload);
    if (!mounted || batch == null) return;
    // User chose "后台下载": the batch keeps running, stay on the preview.
    if (!batch.isTerminal) return;

    final failed = batch.jobs.where((j) => j.state == JobState.failed).length;
    final done = batch.succeeded;
    if (failed == 0 && done > 0) {
      widget.onSaved?.call();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            associated > 0
                ? '已保存 $done 个文件，并关联 $associated 个本地文件'
                : '已保存 $done 个文件到相册',
          ),
        ),
      );
      // Notify history page to refresh
      HostBridge.historyRevision.value = HostBridge.historyRevision.value + 1;
      Navigator.of(context).pop(true);
      return;
    }

    if (failed > 0) {
      // Keep the preview open; the sheet already carries per-row retry.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$failed 个文件保存失败'),
          action: SnackBarAction(
            label: '重试',
            onPressed: () => DownloadManager.instance.retryBatch(batch),
          ),
        ),
      );
    }
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
        actions: [
          if (post.items.isNotEmpty)
            TextButton(
              onPressed: () {
                setState(() {
                  if (_order.length == post.items.length) {
                    _order.clear();
                  } else {
                    _order
                      ..clear()
                      ..addAll([for (var i = 0; i < post.items.length; i++) i]);
                  }
                });
              },
              child: Text(
                _order.length == post.items.length ? '全不选' : '全选',
              ),
            ),
        ],
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
                  onLongPress: () => _toggle(index),
                  child: RepaintBoundary(
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
                            child: _imagesReady
                                ? CoverImage(
                                    key: ValueKey(item.url),
                                    item: item,
                                    referer: refererFor(post.platform),
                                    cacheWidth: 400,
                                  )
                                : const ColoredBox(color: Colors.black12),
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
                        if (_downloaded.contains(index))
                          Positioned(
                            top: 6,
                            left: 6,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.65),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: Colors.greenAccent.withValues(alpha: 0.7),
                                  width: 1,
                                ),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.check_circle,
                                    size: 11,
                                    color: Colors.greenAccent,
                                  ),
                                  SizedBox(width: 3),
                                  Text(
                                    '本地已有',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
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
