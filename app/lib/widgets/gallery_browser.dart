// Unified fullscreen browser component for both PreviewPage (remote mode)
// and HistoryPage / Recent list (local album mode).
// Adheres strictly to docs/design/ui-spec.md and docs/design/gallery-prototype/.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../core/models.dart';
import '../services/gallery_locator_service.dart';
import '../services/history_db.dart';
import '../services/saver.dart';
import '../services/preview_video.dart';
import 'shared.dart';
import 'ai_label_badge.dart';

class GalleryBrowserItem {
  GalleryBrowserItem({
    required this.index,
    required this.type,
    required this.url,
    this.videoUrl,
    this.posterUrl,
    this.fallbacks = const [],
    this.isGif = false,
    this.asset,
    this.liveVideoAsset,
    this.status = FileStatus.found,
    this.filename,
  });

  final int index;
  final String type; // 'image', 'video', 'live'
  final String url;
  final String? videoUrl;
  final String? posterUrl;

  /// Alternative image URLs (mirrors [MediaItem.fallbacks]); without these the
  /// fullscreen viewer and bottom strip fall back to a single URL and show a
  /// broken image whenever the primary CDN host drops the request.
  final List<String> fallbacks;
  final bool isGif;
  final AssetEntity? asset;
  final AssetEntity? liveVideoAsset;
  final FileStatus status;
  final String? filename;

  /// Build the [MediaItem] that drives [CoverImage] with the full URL set.
  MediaItem toMediaItem() => MediaItem(
    type: type,
    url: url,
    videoUrl: videoUrl,
    posterUrl: posterUrl,
    fallbacks: fallbacks,
  );
}

/// Initial selection of the browser. [selectedIndices] holds original post
/// item indices ([GalleryBrowserItem.index]); null means nothing is selected.
Set<int> initialGallerySelection(Set<int>? selectedIndices) =>
    Set<int>.from(selectedIndices ?? const <int>{});

class GalleryBrowserPage extends StatefulWidget {
  const GalleryBrowserPage({
    super.key,
    required this.items,
    this.initialIndex = 0,
    required this.authorName,
    required this.title,
    required this.platform,
    required this.postUrl,
    this.selectedIndices,
    this.onSelectionChanged,
    this.onRedownload,
    this.onReparse,
    this.showSave = false,
    this.aiLabel,
    this.aiLabelSource,
  });

  final List<GalleryBrowserItem> items;
  final int initialIndex;
  final String authorName;
  final String title;
  final String platform;
  final String postUrl;
  final String? aiLabel;
  final String? aiLabelSource;
  final Set<int>? selectedIndices;
  final ValueChanged<Set<int>>? onSelectionChanged;
  final Future<void> Function(int index)? onRedownload;
  final VoidCallback? onReparse;

  /// When opened from the parse-preview flow, shows a 保存 button that closes
  /// the viewer with `true` so the caller can start the save.
  final bool showSave;

  @override
  State<GalleryBrowserPage> createState() => _GalleryBrowserPageState();
}

class _GalleryBrowserPageState extends State<GalleryBrowserPage> {
  late int _currentIndex = widget.initialIndex;
  late final PageController _pageController =
      PageController(initialPage: widget.initialIndex);
  late final ScrollController _thumbController = ScrollController();
  // Selection is keyed by GalleryBrowserItem.index (the original post item
  // index), never by list position. Viewers that do not drive a selection
  // (history) start with nothing selected.
  late final Set<int> _selected = initialGallerySelection(
    widget.selectedIndices,
  );

  double _dragOffset = 0.0;
  bool _isZoomed = false;
  int _pointerCount = 0;
  Offset? _dragStart;
  bool _isPullDownActive = false;

  @override
  void dispose() {
    _pageController.dispose();
    _thumbController.dispose();
    super.dispose();
  }

  void _toggleSelect(int index) {
    setState(() {
      if (_selected.contains(index)) {
        _selected.remove(index);
      } else {
        _selected.add(index);
      }
    });
    widget.onSelectionChanged?.call(_selected);
  }

  Future<void> _shareCurrent() async {
    final item = widget.items[_currentIndex];
    if (item.asset != null) {
      try {
        final file = await item.asset!.file;
        if (file != null && await file.exists()) {
          await SharePlus.instance.share(
            ShareParams(
              text: widget.postUrl,
              files: [XFile(file.path)],
            ),
          );
          return;
        }
      } catch (_) {}
    }
    await SharePlus.instance.share(ShareParams(text: widget.postUrl));
  }

  Future<void> _openOriginal() async {
    final uri = Uri.tryParse(widget.postUrl);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentItem = widget.items.isNotEmpty
        ? widget.items[_currentIndex.clamp(0, widget.items.length - 1)]
        : null;
    final isSelected = currentItem != null && _selected.contains(currentItem.index);

    final opacity = (1.0 - (_dragOffset.abs() / 300)).clamp(0.0, 1.0);

    return Scaffold(
      backgroundColor: Colors.black.withValues(alpha: opacity),
      body: SafeArea(
        child: Listener(
          onPointerDown: (event) {
            _pointerCount++;
            if (_pointerCount == 1) {
              if (!_isZoomed) {
                _dragStart = event.position;
                _isPullDownActive = false;
              }
            } else {
              _dragStart = null;
              _isPullDownActive = false;
              if (_dragOffset > 0) {
                setState(() => _dragOffset = 0.0);
              }
            }
          },
          onPointerMove: (event) {
            if (_pointerCount != 1 || _isZoomed || _dragStart == null) return;
            final dy = event.position.dy - _dragStart!.dy;
            final dx = event.position.dx - _dragStart!.dx;

            if (!_isPullDownActive) {
              // Initiate downward pull only when dragging straight down
              if (dy > 18 && dy > dx.abs() * 1.5) {
                _isPullDownActive = true;
              } else if (dx.abs() > 18 || dy < -18) {
                // Horizontal swipe (for PageView) or upward swipe
                _dragStart = null;
                return;
              }
            }

            if (_isPullDownActive) {
              final offset = (dy - 18).clamp(0.0, 400.0);
              setState(() {
                _dragOffset = offset;
              });
            }
          },
          onPointerUp: (event) {
            _pointerCount = (_pointerCount - 1).clamp(0, 10);
            if (_pointerCount == 0) {
              if (_isPullDownActive && _dragOffset > 150.0) {
                Navigator.of(context).pop();
              } else if (_dragOffset > 0) {
                setState(() {
                  _dragOffset = 0.0;
                  _isPullDownActive = false;
                  _dragStart = null;
                });
              } else {
                _isPullDownActive = false;
                _dragStart = null;
              }
            }
          },
          onPointerCancel: (event) {
            _pointerCount = (_pointerCount - 1).clamp(0, 10);
            if (_pointerCount == 0) {
              _isPullDownActive = false;
              _dragStart = null;
              if (_dragOffset > 0) {
                setState(() => _dragOffset = 0.0);
              }
            }
          },
          child: Transform.translate(
            offset: Offset(0, _dragOffset),
            child: Stack(
              children: [
                // 1. Horizontal PageView
                PageView.builder(
                  controller: _pageController,
                  physics: (_isZoomed || _pointerCount > 1)
                      ? const NeverScrollableScrollPhysics()
                      : const BouncingScrollPhysics(),
                  itemCount: widget.items.length,
                  onPageChanged: (idx) {
                    setState(() {
                      _currentIndex = idx;
                      _isZoomed = false;
                    });
                    // Scroll thumbnail into view
                    if (_thumbController.hasClients) {
                      _thumbController.animateTo(
                        idx * 56.0,
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeOut,
                      );
                    }
                  },
                  itemBuilder: (context, idx) {
                    final item = widget.items[idx];
                    return _BrowserItemView(
                      item: item,
                      platform: widget.platform,
                      onZoomChanged: (zoomed) {
                        if (_isZoomed != zoomed) {
                          setState(() => _isZoomed = zoomed);
                        }
                      },
                      onRedownload: widget.onRedownload != null
                          ? () => widget.onRedownload!(item.index)
                          : null,
                      onToggleSelect: () => _toggleSelect(item.index),
                    );
                  },
                ),

                // 2. Top Bar
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withValues(alpha: 0.7),
                          Colors.transparent,
                        ],
                      ),
                    ),
                    child: Row(
                      children: [
                        // Close button
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.white, size: 24),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                        const SizedBox(width: 8),
                        // Title / Subtitle
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '${_currentIndex + 1} / ${widget.items.length}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              if (widget.authorName.isNotEmpty || widget.title.isNotEmpty)
                                Text(
                                  [
                                    if (widget.authorName.isNotEmpty) widget.authorName,
                                    if (widget.title.isNotEmpty) widget.title,
                                  ].join(' · '),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 12,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        AiLabelBadge(text: widget.aiLabel, source: widget.aiLabelSource),
                        // Checkbox
                        GestureDetector(
                          onTap: currentItem != null
                              ? () => _toggleSelect(currentItem.index)
                              : null,
                          child: Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: isSelected
                                  ? const Color(0xFFFF2442)
                                  : Colors.white.withValues(alpha: 0.2),
                              border: Border.all(
                                color: isSelected ? Colors.transparent : Colors.white70,
                                width: 2,
                              ),
                            ),
                            child: isSelected
                                ? const Icon(Icons.check, color: Colors.white, size: 18)
                                : null,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // Permission hint (self-hides once album access is granted).
                const Positioned(
                  top: 56,
                  left: 16,
                  right: 16,
                  child: _GalleryPermissionHint(),
                ),

                // 3. Bottom Strip + Action Bar
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [
                          Colors.black.withValues(alpha: 0.85),
                          Colors.transparent,
                        ],
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Thumbnails strip
                        if (widget.items.length > 1)
                          SizedBox(
                            height: 56,
                            child: ListView.builder(
                              controller: _thumbController,
                              scrollDirection: Axis.horizontal,
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              itemCount: widget.items.length,
                              itemBuilder: (context, idx) {
                                final it = widget.items[idx];
                                final isCur = idx == _currentIndex;
                                final isSel = _selected.contains(it.index);

                                return GestureDetector(
                                  onTap: () {
                                    _pageController.animateToPage(
                                      idx,
                                      duration: const Duration(milliseconds: 250),
                                      curve: Curves.easeInOut,
                                    );
                                  },
                                  child: Container(
                                    width: 44,
                                    height: 44,
                                    margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: isCur ? Colors.white : Colors.transparent,
                                        width: 2,
                                      ),
                                    ),
                                    clipBehavior: Clip.antiAlias,
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        _ThumbnailImage(
                                          item: it,
                                          platform: widget.platform,
                                        ),
                                        if (isSel)
                                          Positioned(
                                            top: 2,
                                            right: 2,
                                            child: Container(
                                              width: 12,
                                              height: 12,
                                              decoration: const BoxDecoration(
                                                color: Color(0xFFFF2442),
                                                shape: BoxShape.circle,
                                              ),
                                              child: const Icon(
                                                Icons.check,
                                                color: Colors.white,
                                                size: 9,
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

                        // Bottom action bar
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                          child: Row(
                            children: [
                              // Left info text
                              Text(
                                _selected.isEmpty
                                    ? '点右上角选择'
                                    : '已选 ${_selected.length} 项',
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 13,
                                ),
                              ),
                              const Spacer(),
                              // Actions
                              if (!widget.showSave && widget.onReparse != null)
                                Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: TextButton.icon(
                                    style: TextButton.styleFrom(
                                      backgroundColor: Colors.white12,
                                      foregroundColor: Colors.white,
                                      shape: const StadiumBorder(),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 6,
                                      ),
                                    ),
                                    onPressed: widget.onReparse,
                                    icon: const Icon(Icons.refresh, size: 16),
                                    label: const Text('重新解析', style: TextStyle(fontSize: 12)),
                                  ),
                                ),
                              if (!widget.showSave)
                                IconButton(
                                  style: IconButton.styleFrom(
                                    backgroundColor: Colors.white12,
                                    foregroundColor: Colors.white,
                                  ),
                                  icon: const Icon(Icons.open_in_new, size: 18),
                                  tooltip: '打开原帖',
                                  onPressed: _openOriginal,
                                ),
                              const SizedBox(width: 8),
                              if (widget.showSave)
                                ElevatedButton.icon(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFFFF2442),
                                    foregroundColor: Colors.white,
                                    shape: const StadiumBorder(),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 8,
                                    ),
                                  ),
                                  // Close the viewer and let the preview page
                                  // start the save with the synced selection.
                                  onPressed: () =>
                                      Navigator.of(context).pop(true),
                                  icon: const Icon(Icons.download, size: 16),
                                  label: const Text('保存', style: TextStyle(fontSize: 13)),
                                )
                              else
                                ElevatedButton.icon(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFFFF2442),
                                    foregroundColor: Colors.white,
                                    shape: const StadiumBorder(),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 8,
                                    ),
                                  ),
                                  onPressed: _shareCurrent,
                                  icon: const Icon(Icons.share, size: 16),
                                  label: const Text('分享', style: TextStyle(fontSize: 13)),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Top hint shown when the album has no read permission: local originals
/// can't be shown until access is granted. Self-hides when access is granted.
class _GalleryPermissionHint extends StatelessWidget {
  const _GalleryPermissionHint();

  @override
  Widget build(BuildContext context) {
    final locator = GalleryLocatorService.instance;
    return ListenableBuilder(
      listenable: locator,
      builder: (context, _) {
        if (locator.hasAccess) return const SizedBox.shrink();
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              const Icon(Icons.photo_outlined, size: 20, color: Colors.black87),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  '授权相册访问后可显示本地原图',
                  style: TextStyle(color: Colors.black87, fontSize: 13),
                ),
              ),
              TextButton(
                onPressed: () => locator.requestPermission(),
                child: const Text('授权'),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ThumbnailImage extends StatelessWidget {
  const _ThumbnailImage({required this.item, required this.platform});
  final GalleryBrowserItem item;
  final String platform;

  @override
  Widget build(BuildContext context) {
    if (item.status == FileStatus.notFound) {
      return Container(
        color: Colors.grey.shade800,
        child: const Icon(Icons.broken_image, size: 18, color: Colors.white54),
      );
    }
    if (item.asset != null) {
      return AssetEntityImage(
        item.asset!,
        isOriginal: false,
        thumbnailSize: const ThumbnailSize.square(120),
        fit: BoxFit.cover,
      );
    }
    return CoverImage(
      item: item.toMediaItem(),
      referer: refererFor(platform),
      fit: BoxFit.cover,
      cacheWidth: 400,
    );
  }
}

class _BrowserItemView extends StatefulWidget {
  const _BrowserItemView({
    required this.item,
    required this.platform,
    this.onZoomChanged,
    this.onRedownload,
    this.onToggleSelect,
  });

  final GalleryBrowserItem item;
  final String platform;
  final ValueChanged<bool>? onZoomChanged;
  final Future<void> Function()? onRedownload;
  final VoidCallback? onToggleSelect;

  @override
  State<_BrowserItemView> createState() => _BrowserItemViewState();
}

class _BrowserItemViewState extends State<_BrowserItemView> {
  VideoPlayerController? _videoController;
  bool _isPlaying = false;
  bool _controlsVisible = true;
  Timer? _hideTimer;
  bool _isLiveHolding = false;
  bool _redownloading = false;
  bool _isNotFound = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.item.status == FileStatus.notFound) {
      _isNotFound = true;
    } else if (widget.item.asset != null) {
      _checkAssetExistence();
    }

    if (widget.item.status == FileStatus.found) {
      if (widget.item.isGif || widget.item.type == 'video') {
        _initVideo();
      }
    }
  }

  Future<void> _checkAssetExistence() async {
    final a = widget.item.asset;
    if (a != null) {
      try {
        final exists = await a.exists;
        if (!exists && mounted) {
          setState(() => _isNotFound = true);
        }
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _videoController?.dispose();
    super.dispose();
  }

  /// Keep the play/pause icons and the controls bar in sync with the player,
  /// whatever triggered the change (tap, video end, app pause...).
  void _attachVideoListener(VideoPlayerController controller) {
    controller.addListener(_onVideoValue);
  }

  void _onVideoValue() {
    final c = _videoController;
    if (c == null || !mounted) return;
    if (c.value.hasError) {
      setState(() => _error = previewPlaybackError(widget.platform));
      return;
    }
    final playing = c.value.isPlaying;
    if (playing == _isPlaying && (playing || _controlsVisible)) return;
    if (!playing) _hideTimer?.cancel();
    setState(() {
      _isPlaying = playing;
      if (!playing) _controlsVisible = true;
    });
    if (playing) _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      final c = _videoController;
      if (c != null && c.value.isPlaying) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  Future<void> _initVideo() async {
    final it = widget.item;
    try {
      VideoPlayerController controller;
      if (it.asset != null) {
        final f = await it.asset!.file;
        if (f != null && await f.exists()) {
          controller = VideoPlayerController.file(f);
        } else {
          final targetUrl = it.videoUrl ?? it.url;
          controller = await networkPreviewController(targetUrl, widget.platform);
        }
      } else {
        final targetUrl = it.videoUrl ?? it.url;
        controller = await networkPreviewController(targetUrl, widget.platform);
      }

      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }

      if (it.isGif) {
        await controller.setLooping(true);
        await controller.setVolume(0);
        await controller.play();
        _isPlaying = true;
      } else {
        // Don't autoplay: leave the first frame up with a play button so the
        // user starts playback (and audio) on purpose.
        await controller.pause();
        _isPlaying = false;
        _controlsVisible = true;
      }

      setState(() => _videoController = controller);
      _attachVideoListener(controller);
    } catch (e) {
      if (mounted) setState(() => _error = previewPlaybackError(widget.platform));
    }
  }

  Future<void> _startLiveMotion() async {
    if (_isLiveHolding) return;
    setState(() => _isLiveHolding = true);

    try {
      final it = widget.item;
      VideoPlayerController controller;

      if (it.liveVideoAsset != null) {
        final f = await it.liveVideoAsset!.file;
        if (f != null && await f.exists()) {
          controller = VideoPlayerController.file(f);
        } else {
          final videoUrl = it.videoUrl;
          if (videoUrl == null || videoUrl.isEmpty) return;
          controller = await _createPlayerController(videoUrl);
        }
      } else {
        final videoUrl = it.videoUrl;
        if (videoUrl == null || videoUrl.isEmpty) return;
        controller = await _createPlayerController(videoUrl);
      }

      await controller.initialize();
      await controller.setLooping(true);
      await controller.setVolume(0);
      if (!mounted || !_isLiveHolding) {
        await controller.dispose();
        return;
      }
      _videoController = controller;
      await controller.play();
      setState(() {});
    } catch (_) {
      if (mounted) setState(() => _isLiveHolding = false);
    }
  }

  Future<VideoPlayerController> _createPlayerController(String target) async {
    if (target.startsWith('http://') || target.startsWith('https://')) {
      return await networkPreviewController(target, widget.platform);
    } else if (target.startsWith('content://')) {
      return VideoPlayerController.contentUri(Uri.parse(target));
    } else {
      return VideoPlayerController.file(File(target));
    }
  }

  Future<void> _stopLiveMotion() async {
    setState(() => _isLiveHolding = false);
    final c = _videoController;
    _videoController = null;
    if (c != null) {
      await c.pause();
      await c.dispose();
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final it = widget.item;

    // 1. Missing file: "已从相册删除" placeholder + [重新下载]
    if (it.status == FileStatus.notFound || _isNotFound) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white10,
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Icon(
                Icons.broken_image_outlined,
                color: Colors.white60,
                size: 64,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              '已从相册删除',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '相册中未找到此文件',
              style: TextStyle(color: Colors.white54, fontSize: 13),
            ),
            if (widget.onRedownload != null) ...[
              const SizedBox(height: 20),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFF2442),
                  foregroundColor: Colors.white,
                  shape: const StadiumBorder(),
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                ),
                onPressed: _redownloading
                    ? null
                    : () async {
                        setState(() => _redownloading = true);
                        try {
                          await widget.onRedownload!();
                        } finally {
                          if (mounted) setState(() => _redownloading = false);
                        }
                      },
                icon: _redownloading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.download, size: 18),
                label: Text(_redownloading ? '下载中...' : '重新下载'),
              ),
            ],
          ],
        ),
      );
    }

    // 2. GIF playback: auto loop, muted, tap to pause/play, GIF badge
    if (it.isGif) {
      final c = _videoController;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        // Long-press toggles selection (tap still pauses/plays).
        onLongPress: widget.onToggleSelect,
        onTap: () {
          if (c != null && c.value.isInitialized) {
            setState(() {
              if (c.value.isPlaying) {
                c.pause();
                _isPlaying = false;
              } else {
                c.play();
                _isPlaying = true;
              }
            });
          }
        },
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (c != null && c.value.isInitialized)
              Center(
                child: AspectRatio(
                  aspectRatio: c.value.aspectRatio,
                  child: VideoPlayer(c),
                ),
              )
            else if (_error != null)
              Center(
                child: Text('播放失败：$_error', style: const TextStyle(color: Colors.white)),
              )
            else
              const Center(child: CircularProgressIndicator(color: Colors.white)),

            // "GIF" Badge top-left
            Positioned(
              top: 56,
              left: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text(
                  'GIF',
                  style: TextStyle(
                    color: Colors.black,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),

            // Paused indicator
            if (c != null && c.value.isInitialized && !_isPlaying)
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.5),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.play_arrow, color: Colors.white, size: 36),
              ),
          ],
        ),
      );
    }

    // 3. Regular Video playback: starts paused, tap the play button to start
    if (it.type == 'video') {
      final c = _videoController;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        // Long-press toggles selection; tap shows/hides the controls bar.
        onLongPress: widget.onToggleSelect,
        // Tap the video itself toggles the controls bar, never playback.
        onTap: () => setState(() {
          _controlsVisible = !_controlsVisible;
          if (_controlsVisible) {
            _scheduleHide();
          } else {
            _hideTimer?.cancel();
          }
        }),
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (c != null && c.value.isInitialized)
              Center(
                child: AspectRatio(
                  aspectRatio: c.value.aspectRatio == 0 ? 16 / 9 : c.value.aspectRatio,
                  child: VideoPlayer(c),
                ),
              )
            else if (_error != null)
              Center(
                child: Text('播放失败：$_error', style: const TextStyle(color: Colors.white)),
              )
            else
              const Center(child: CircularProgressIndicator(color: Colors.white)),

            // Tap-to-play overlay: videos don't autoplay.
            if (c != null && c.value.isInitialized && !_isPlaying)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => c.play(),
                child: Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.45),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.play_arrow,
                    color: Colors.white,
                    size: 44,
                  ),
                ),
              ),

            // Video control overlay: auto-hides a few seconds after playback
            // starts so it doesn't cover the picture.
            if (c != null && c.value.isInitialized && _controlsVisible)
              Positioned(
                bottom: 100,
                left: 16,
                right: 16,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    children: [
                      IconButton(
                        icon: Icon(
                          c.value.isPlaying ? Icons.pause : Icons.play_arrow,
                          color: Colors.white,
                        ),
                        onPressed: () {
                          if (c.value.isPlaying) {
                            c.pause();
                          } else {
                            c.play();
                          }
                        },
                      ),
                      Expanded(
                        child: VideoProgressIndicator(
                          c,
                          allowScrubbing: true,
                          colors: const VideoProgressColors(
                            playedColor: Color(0xFFFF2442),
                            bufferedColor: Colors.white24,
                            backgroundColor: Colors.white12,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ValueListenableBuilder<VideoPlayerValue>(
                        valueListenable: c,
                        builder: (context, value, _) => IconButton(
                          icon: Icon(
                            value.volume == 0
                                ? Icons.volume_off
                                : Icons.volume_up,
                            color: Colors.white,
                            size: 20,
                          ),
                          onPressed: () {
                            c.setVolume(value.volume == 0 ? 1.0 : 0.0);
                          },
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

    // 4. Live Photo: static cover + "LIVE" badge + "长按播放实况" + press to play loop
    if (it.type == 'live') {
      final c = _videoController;
      final showVideo = _isLiveHolding && c != null && c.value.isInitialized;

      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPressStart: (_) => _startLiveMotion(),
        onLongPressEnd: (_) => _stopLiveMotion(),
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (showVideo)
              Center(
                child: AspectRatio(
                  aspectRatio: c.value.aspectRatio == 0 ? 1 : c.value.aspectRatio,
                  child: VideoPlayer(c),
                ),
              )
            else
              InteractiveViewer(
                minScale: 1.0,
                maxScale: 4.0,
                child: Center(
                  child: it.asset != null
                      ? AssetEntityImage(
                          it.asset!,
                          isOriginal: true,
                          fit: BoxFit.contain,
                        )
                      : Stack(
                          fit: StackFit.passthrough,
                          alignment: Alignment.center,
                          children: [
                            CoverImage(
                              item: it.toMediaItem(),
                              referer: refererFor(widget.platform),
                              fit: BoxFit.contain,
                              cacheWidth: 400,
                            ),
                            CoverImage(
                              item: it.toMediaItem(),
                              referer: refererFor(widget.platform),
                              fit: BoxFit.contain,
                              cacheWidth: 1080,
                              placeholder: const SizedBox.shrink(),
                            ),
                          ],
                        ),
                ),
              ),

            // "LIVE" Badge top-left
            Positioned(
              top: 56,
              left: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text(
                  'LIVE',
                  style: TextStyle(
                    color: Colors.black,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),

            // Bottom hint
            if (!_isLiveHolding)
              Positioned(
                bottom: 110,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Text(
                    '长按播放实况',
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ),
              ),
          ],
        ),
      );
    }

    // 5. Standard Image: Zoomable with double-tap zoom & pinch pan
    return _ZoomableImageView(
      item: it,
      platform: widget.platform,
      onZoomChanged: widget.onZoomChanged,
      onLongPress: widget.onToggleSelect,
    );
  }
}

class _ZoomableImageView extends StatefulWidget {
  const _ZoomableImageView({
    required this.item,
    required this.platform,
    this.onZoomChanged,
    this.onLongPress,
  });

  final GalleryBrowserItem item;
  final String platform;
  final ValueChanged<bool>? onZoomChanged;
  final VoidCallback? onLongPress;

  @override
  State<_ZoomableImageView> createState() => _ZoomableImageViewState();
}

class _ZoomableImageViewState extends State<_ZoomableImageView>
    with SingleTickerProviderStateMixin {
  late final TransformationController _transformationController =
      TransformationController();
  TapDownDetails? _doubleTapDetails;
  late final AnimationController _animController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 250),
  );

  @override
  void initState() {
    super.initState();
    _transformationController.addListener(_handleTransform);
  }

  @override
  void dispose() {
    _transformationController.removeListener(_handleTransform);
    _transformationController.dispose();
    _animController.dispose();
    super.dispose();
  }

  void _handleTransform() {
    final scale = _transformationController.value.getMaxScaleOnAxis();
    widget.onZoomChanged?.call(scale > 1.05);
  }

  void _onDoubleTap() {
    final currentScale = _transformationController.value.getMaxScaleOnAxis();
    final Matrix4 target;
    if (currentScale < 1.5) {
      final pos = _doubleTapDetails?.localPosition ?? Offset.zero;
      const targetScale = 2.5;
      final x = -pos.dx * (targetScale - 1);
      final y = -pos.dy * (targetScale - 1);
      target = Matrix4.identity()
        ..translateByDouble(x, y, 0.0, 1.0)
        ..scaleByDouble(targetScale, targetScale, 1.0, 1.0);
    } else {
      target = Matrix4.identity();
    }

    final animation = Matrix4Tween(
      begin: _transformationController.value,
      end: target,
    ).animate(CurvedAnimation(parent: _animController, curve: Curves.easeOutCubic));

    void listener() {
      _transformationController.value = animation.value;
    }

    animation.addListener(listener);
    _animController.forward(from: 0).then((_) {
      animation.removeListener(listener);
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onDoubleTapDown: (details) => _doubleTapDetails = details,
      onDoubleTap: _onDoubleTap,
      onLongPress: widget.onLongPress,
      child: InteractiveViewer(
        transformationController: _transformationController,
        minScale: 1.0,
        maxScale: 5.0,
        clipBehavior: Clip.none,
        child: Center(
          child: widget.item.asset != null
              ? AssetEntityImage(
                  widget.item.asset!,
                  isOriginal: true,
                  fit: BoxFit.contain,
                )
              : Stack(
                  fit: StackFit.passthrough,
                  alignment: Alignment.center,
                  children: [
                    CoverImage(
                      item: widget.item.toMediaItem(),
                      referer: refererFor(widget.platform),
                      fit: BoxFit.contain,
                      cacheWidth: 400,
                    ),
                    CoverImage(
                      item: widget.item.toMediaItem(),
                      referer: refererFor(widget.platform),
                      fit: BoxFit.contain,
                      cacheWidth: 1080,
                      placeholder: const SizedBox.shrink(),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

