// History page cards: waterfall post card, list row, all-media card and
// creator card, plus the shared local-thumbnail widget and badge helpers.
// Thumbnails read the local album (via GalleryLocatorService) and never hit
// the CDN, so signed-URL expiry can't break them.

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import '../core/models.dart';
import '../services/gallery_locator_service.dart';
import '../services/history_db.dart';
import '../services/live_pairs.dart';
import '../services/local_thumbnail_tiers.dart';
import '../theme/app_theme.dart';
import 'shared.dart';
import 'verified_asset_image.dart';
import 'ai_label_badge.dart';

/// Short saved-time label, e.g. "今天 18:24", "昨天 09:10", "10-12 09:10".
String formatSavedAt(DateTime time) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final date = DateTime(time.year, time.month, time.day);
  final hm =
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  final diff = today.difference(date).inDays;
  if (diff == 0) return '今天 $hm';
  if (diff == 1) return '昨天 $hm';
  if (time.year == now.year) {
    return '${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')} $hm';
  }
  return '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')}';
}

/// The representative (cover) media item of a post: the item matching the
/// lowest-index saved file, else the first parsed item.
///
/// Built from the rows the browser may show, so a post whose first file left
/// the device still points at that same item (its placeholder) instead of
/// silently jumping to another one.
MediaItem? coverItemFor(HistoryRecord record) {
  final post = record.toPost();
  if (post.items.isEmpty) return null;
  final visible = record.visibleFiles;
  if (visible.isNotEmpty) {
    final idx = visible.first.itemIndex;
    final is1Based = visible.every((f) => f.itemIndex > 0);
    final zeroBased = is1Based ? idx - 1 : idx;
    if (zeroBased >= 0 && zeroBased < post.items.length) {
      return post.items[zeroBased];
    }
    return post.items.where((item) => item.cacheItemIndex == zeroBased).firstOrNull;
  }
  return post.items.first;
}

/// Human type bucket used for badges and "按类型" grouping.
String mediaKindLabel(MediaItem? item) {
  if (item == null) return '图片';
  if (item.type == 'video') return item.isGif == true ? 'GIF' : '视频';
  if (item.type == 'live') return 'Live 图';
  return '图片';
}

/// A post's type bucket (by its cover), used to group the 帖子 view by type.
String postKindLabel(HistoryRecord record) =>
    mediaKindLabel(coverItemFor(record));

double aspectRatioFor(MediaItem? item) {
  final w = item?.width?.toDouble();
  final h = item?.height?.toDouble();
  if (w != null && h != null && w > 0 && h > 0) {
    return (w / h).clamp(0.5, 2.0);
  }
  return 0.75;
}

/// Padding the waterfall card keeps inside its column cell (back layer peek).
const double kWaterfallCardInset = 5;

/// Exact height of a [WaterfallPostCard] in a column [width] wide.
///
/// The card is a [AspectRatio] on the cover's own size, inset by
/// [kWaterfallCardInset] on the right and bottom, so its height is known from
/// the record before the card exists. The waterfall uses this instead of
/// building a card to measure it (v1.11 batch 2: measuring off-screen cards
/// flooded the local thumbnail pipeline).
double waterfallCardHeight(HistoryRecord record, double width) {
  final inner = (width - kWaterfallCardInset).clamp(0.0, double.infinity);
  return inner / aspectRatioFor(coverItemFor(record)) + kWaterfallCardInset;
}

/// Exact height of an [AllMediaCard] in a column [width] wide.
double allMediaCardHeight(MediaItem? item, double width) =>
    width / aspectRatioFor(item);

/// The media item an [AllMediaCard] shows for [itemIndex].
MediaItem? allMediaItemFor(HistoryRecord record, int itemIndex) {
  final post = record.toPost();
  final visible = record.visibleFiles;
  final is1Based = visible.isNotEmpty &&
      visible.every((f) => f.itemIndex > 0);
  final zeroBased = is1Based ? itemIndex - 1 : itemIndex;
  if (zeroBased >= 0 && zeroBased < post.items.length) {
    return post.items[zeroBased];
  }
  if (itemIndex >= 0 && itemIndex < post.items.length) {
    return post.items[itemIndex];
  }
  return null;
}

/// Local-album thumbnail for a record (optionally a specific file). Falls back
/// to a shimmer while locating, a "deleted" placeholder when fully authorized
/// and missing, or a neutral placeholder otherwise. Never uses the CDN.
class HistoryThumb extends StatelessWidget {
  const HistoryThumb({
    super.key,
    required this.record,
    this.itemIndex,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.brokenIconSize = 24,
    this.thumbnailSize = LocalThumbnailTiers.medium,
  });

  final HistoryRecord record;
  final int? itemIndex;
  final BoxFit fit;
  final double? width;
  final double? height;
  final double brokenIconSize;

  /// Which of the two local thumbnail tiers this thumb asks for (v1.11 batch
  /// 3). The default is the history cover; a cell in the creator card's 2×2
  /// grid asks for [LocalThumbnailTiers.small].
  final ThumbnailSize thumbnailSize;

  @override
  Widget build(BuildContext context) {
    final locator = GalleryLocatorService.instance;
    final items = record.toPost().items;
    final visible = record.visibleFiles;
    final index = itemIndex == null
        ? 0
        : (visible.every((f) => f.itemIndex > 0)
              ? itemIndex! - 1
              : itemIndex!);
    final remote = itemIndex == null ? coverItemFor(record)
        : items.where((item) => item.cacheItemIndex == index).firstOrNull ??
            (index >= 0 && index < items.length ? items[index] : null);

    AssetEntity? asset;
    HistoryFile? matched;
    for (final f in visible) {
      if (itemIndex != null && f.itemIndex != itemIndex) continue;
      matched ??= f;
      asset =
          locator.getAssetById(f.mediaId) ??
          locator.locateAsset(f, record.postId);
      if (asset != null) break;
    }

    // A still this device cannot show is never handed to the platform decoder:
    // its thumbnail would stall the shared decode channel (build 46). The card
    // shows the post's own cover instead, with the warning strip.
    final undecodable = matched?.undecodable == true;

    // The album already answered that this item is not on the device: the card
    // keeps its broken-file icon and never falls back to the network cover
    // (v1.11 batch 4). A lookup that merely failed produces no such row.
    final coverMissing =
        asset == null && matched != null && isMissingHistoryFile(matched);

    if (asset != null && !undecodable) {
      return _withDecodeWarning(
        VerifiedAssetImage(
          asset,
          fallback: CoverImage(
            item: remote ?? MediaItem(type: 'image', url: ''),
            platform: (record.platform),
            fit: fit,
            width: width,
            height: height,
          ),
          isOriginal: false,
          thumbnailSize: thumbnailSize,
          fit: fit,
          width: width,
          height: height,
        ),
        record: record,
        itemIndex: itemIndex,
        width: width,
        height: height,
      );
    }

    if (!coverMissing && remote != null && remote.url.startsWith('http')) {
      return _withDecodeWarning(
        CoverImage(
          item: remote,
          platform: (record.platform),
          fit: fit,
          width: width,
          height: height,
        ),
        record: record,
        itemIndex: itemIndex,
        width: width,
        height: height,
      );
    }

    final isUnlocated = visible.any(
      (f) =>
          f.status == FileStatus.unknown &&
          (f.mediaId == null || f.mediaId!.isEmpty),
    );
    if (!coverMissing && isUnlocated && (locator.isScanning || !locator.scanned)) {
      return ShimmerBox(width: width, height: height);
    }

    final allNotFound =
        visible.isNotEmpty && visible.every((f) => f.status == FileStatus.notFound);
    final missing =
        coverMissing ||
        (locator.isFullyAuthorized && locator.scanned && allNotFound);

    return _withDecodeWarning(
      ColoredBox(
        color: missing
            ? (Theme.of(context).brightness == Brightness.dark
                  ? Colors.white10
                  : Colors.grey.shade200)
            : SecondaryBg.beige(context),
        child: Center(
          child: Icon(
            missing ? Icons.broken_image : Icons.photo_outlined,
            size: brokenIconSize,
            color: AppTokens.textSecondary,
          ),
        ),
      ),
      record: record,
      itemIndex: itemIndex,
      width: width,
      height: height,
    );
  }

  /// Adds the "this device cannot display it" strip over a card whose still the
  /// platform decoders reject. Purely presentational: the replacement path is
  /// the viewer's re-download, which asks before deleting the old file.
  Widget _withDecodeWarning(
    Widget child, {
    required HistoryRecord record,
    required int? itemIndex,
    double? width,
    double? height,
  }) {
    final flagged = record.files.any(
      (f) =>
          (itemIndex == null || f.itemIndex == itemIndex) &&
          f.undecodable == true,
    );
    if (!flagged) return child;
    return Stack(
      fit: StackFit.passthrough,
      children: [
        child,
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: IgnorePointer(
            child: ColoredBox(
              color: Colors.black.withValues(alpha: 0.55),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                child: Text(
                  '本机无法显示此格式',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.white, fontSize: 10),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Dark translucent capsule badge (multi count / video duration).
/// Dimmed cover with a progress ring and percent, shown on a history card
/// while its post is still being downloaded.
class DownloadingOverlay extends StatelessWidget {
  const DownloadingOverlay({
    super.key,
    required this.progress,
    this.compact = false,
    this.paused = false,
    this.stalled = false,
    this.failed = false,
    this.waitingForNetwork = false,
    this.partial = false,
    this.failureReason,
    this.onTogglePause,
    this.onCancel,
  });

  final double progress;
  final bool compact;

  /// The user paused the download: shows a play icon and "已暂停".
  final bool paused;

  /// No sign of life for a while: the toggle becomes "retry".
  final bool stalled;
  final bool failed;

  /// The system has no connection: the batch keeps its place in the queue and
  /// resumes by itself, so the overlay explains the wait instead of spinning
  /// silently (v1.11 batch 2). Display only — nothing here pauses anything.
  final bool waitingForNetwork;

  final bool partial;

  /// Short failure reason ("存储空间不足", "HTTP 403", ...) shown in the label.
  final String? failureReason;

  /// Pause / resume (retry when [stalled]); null hides the control.
  final VoidCallback? onTogglePause;

  /// Cancel and discard the download; null hides the control.
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final pct = (progress.clamp(0.0, 1.0) * 100).round();
    final size = compact ? 28.0 : 44.0;
    final reason = failureReason?.isNotEmpty == true ? '（$failureReason）' : '';
    final label = failed ? (partial ? '部分保存成功$reason，点击重试' : '下载失败$reason，点击重试') : paused ? '已暂停 $pct%' : (stalled ? '已停滞 $pct%' : '下载中 $pct%');
    final shownLabel = !failed && !paused && waitingForNetwork
        ? '等待网络…联网后自动继续'
        : label;
    final toggleIcon = paused
        ? Icons.play_arrow_rounded
        : (stalled || failed ? Icons.refresh : Icons.pause_rounded);
    final toggleTip = failed ? '重试' : paused ? '继续下载' : (stalled ? '重试' : '暂停下载');
    final actionSize = compact ? 18.0 : 22.0;

    Widget action(IconData icon, String tip, VoidCallback onTap) {
      return IconButton(
        tooltip: tip,
        onPressed: onTap,
        icon: Icon(icon, color: Colors.white, size: actionSize),
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        constraints: BoxConstraints.tightFor(
          width: compact ? 28 : 36,
          height: compact ? 28 : 36,
        ),
        style: IconButton.styleFrom(backgroundColor: Colors.black38,
          minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
      );
    }

    return Semantics(
      label: shownLabel,
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.45),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: size,
                height: size,
                child: failed ? const Icon(Icons.error_outline, color: Colors.white) : CircularProgressIndicator(
                  // Indeterminate until the first bytes arrive.
                  value: paused || progress > 0
                      ? progress.clamp(0.0, 1.0)
                      : null,
                  strokeWidth: 3,
                  color: paused ? Colors.white54 : Colors.white,
                  backgroundColor: Colors.white24,
                ),
              ),
              if (!compact) ...[
                const SizedBox(height: 6),
                Text(
                  shownLabel,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              if (onTogglePause != null || onCancel != null) ...[
                SizedBox(height: compact ? 2 : 6),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (onTogglePause != null)
                      action(toggleIcon, toggleTip, onTogglePause!),
                    if (onTogglePause != null && onCancel != null)
                      SizedBox(width: compact ? 4 : 8),
                    if (onCancel != null)
                      action(Icons.close, '取消下载', onCancel!),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class DarkBadge extends StatelessWidget {
  const DarkBadge({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
      ),
      child: child,
    );
  }
}

/// White capsule badge (LIVE / GIF / 视频 type markers).
class WhiteBadge extends StatelessWidget {
  const WhiteBadge({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.black,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

String? videoDurationLabel(MediaItem? item) {
  final duration = item?.duration;
  if (duration == null || !duration.isFinite) return null;
  final total = duration.round();
  final mm = (total ~/ 60).toString();
  final ss = (total % 60).toString().padLeft(2, '0');
  return '$mm:$ss';
}

/// Overlays shared by the waterfall cover and the all-media card: item count
/// (top-right), video ▶/duration and LIVE/GIF (top-left).
List<Widget> coverBadges(
  BuildContext context, {
  required MediaItem? cover,
  required int itemCount,
  bool showInfo = true,
  bool notOriginal = false,
}) {
  final widgets = <Widget>[];
  if (notOriginal) {
    // A saved image smaller than the platform's declared size.
    widgets.add(
      const Positioned(
        top: 34,
        left: 8,
        child: DarkBadge(
          child: Text(
            '非原图',
            style: TextStyle(color: Colors.white, fontSize: 10),
          ),
        ),
      ),
    );
  }
  if (showInfo && cover != null) {
    final kind = mediaKindLabel(cover);
    if (kind == 'LIVE' || kind == 'Live 图') {
      widgets.add(
        const Positioned(top: 8, left: 8, child: WhiteBadge(label: 'LIVE')),
      );
    } else if (kind == 'GIF') {
      widgets.add(
        const Positioned(top: 8, left: 8, child: WhiteBadge(label: 'GIF')),
      );
    } else if (kind == '视频') {
      final label = videoDurationLabel(cover);
      widgets.add(
        Positioned(
          top: 8,
          left: 8,
          child: DarkBadge(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.play_arrow, color: Colors.white, size: 12),
                if (label != null) ...[
                  const SizedBox(width: 2),
                  Text(
                    label,
                    style: const TextStyle(color: Colors.white, fontSize: 10),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }
  }
  if (itemCount > 1) {
    widgets.add(
      Positioned(
        top: 8,
        right: 8,
        child: DarkBadge(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.collections, color: Colors.white, size: 11),
              const SizedBox(width: 3),
              Text(
                '$itemCount',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
  return widgets;
}

/// Small white pill used on list rows (视频 / LIVE / GIF).
String? listTypeBadge(MediaItem? item) {
  if (item == null) return null;
  if (item.type == 'video') return item.isGif == true ? 'GIF' : '视频';
  if (item.type == 'live') return 'LIVE';
  return null;
}

/// A (record, file) pair identifying one media item to thumbnail.
class HistThumbRef {
  const HistThumbRef(this.record, this.itemIndex);
  final HistoryRecord record;
  final int itemIndex;
}

/// Post card for the 帖子 waterfall: cover keeps its original ratio, with a
/// soft stacked shadow, multi-count / type badges and a bottom gradient label.
class WaterfallPostCard extends StatelessWidget {
  const WaterfallPostCard({
    super.key,
    required this.record,
    required this.onTap,
    this.selectionMode = false,
    this.selected = false,
    this.onLongPress,
    this.onToggleSelect,
    this.downloadProgress,
    this.downloadPaused = false,
    this.downloadStalled = false,
    this.downloadFailed = false,
    this.downloadWaitingForNetwork = false,
    this.downloadFailureReason,
    this.onToggleDownload,
    this.onCancelDownload,
  });

  final HistoryRecord record;
  final VoidCallback onTap;
  final bool selectionMode;
  final bool selected;
  final VoidCallback? onLongPress;
  final VoidCallback? onToggleSelect;

  /// 0..1 while a download of this post is running, null otherwise.
  final double? downloadProgress;
  final bool downloadPaused;
  final bool downloadStalled;
  final bool downloadFailed;

  /// No system connection: the overlay explains the wait (display only).
  final bool downloadWaitingForNetwork;

  final String? downloadFailureReason;

  /// Pause / resume (retry when stalled) and cancel of the running download.
  final VoidCallback? onToggleDownload;
  final VoidCallback? onCancelDownload;

  @override
  Widget build(BuildContext context) {
    final cover = coverItemFor(record);
    final itemCount = savedMediaEntryCount(record.savedFiles);
    final title = (record.title?.isNotEmpty == true) ? record.title! : '无标题';
    final radius = BorderRadius.circular(20);

    return GestureDetector(
      onTap: selectionMode ? onToggleSelect : onTap,
      onLongPress: onLongPress,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Back layer: peeks 5px on the right and bottom so the card has a
          // soft stacked shadow on both edges.
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                borderRadius: radius,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.14),
                    blurRadius: 10,
                    offset: const Offset(2, 5),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 5, bottom: 5),
            child: ClipRRect(
              borderRadius: radius,
              child: AspectRatio(
                aspectRatio: aspectRatioFor(cover),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    HistoryThumb(record: record, fit: BoxFit.cover),
                    // Bottom dark gradient with platform tag + title.
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(10, 22, 10, 10),
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Colors.transparent, Colors.black87],
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Wrap(
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                PlatformTag(
                                  platform: record.platform,
                                  savedDisplayName: record.platformDisplayName,
                                ),
                                AiLabelBadge(
                                  text: record.aiLabel,
                                  source: record.aiLabelSource,
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    ...coverBadges(
                      context,
                      cover: cover,
                      itemCount: itemCount,
                      notOriginal: record.savedFiles.any((f) => f.notOriginal),
                    ),
                    if (downloadProgress != null)
                      Positioned.fill(
                        child: DownloadingOverlay(
                          progress: downloadProgress!,
                          paused: downloadPaused,
                          stalled: downloadStalled,
                          failed: downloadFailed,
                          waitingForNetwork: downloadWaitingForNetwork,
                          failureReason: downloadFailureReason,
                          partial: record.savedFiles.isNotEmpty,
                          // Hidden in multi-select so taps keep selecting.
                          onTogglePause: selectionMode
                              ? null
                              : onToggleDownload,
                          onCancel: selectionMode ? null : onCancelDownload,
                        ),
                      ),
                    if (selectionMode)
                      Positioned(
                        top: 6,
                        right: 6,
                        child: _SelectionDot(selected: selected),
                      ),
                    if (selectionMode && selected)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: radius,
                              border: Border.all(
                                color: AppTokens.primary,
                                width: 2.5,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SelectionDot extends StatelessWidget {
  const _SelectionDot({required this.selected});
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected
            ? AppTokens.primary
            : Colors.black.withValues(alpha: 0.35),
        border: Border.all(color: Colors.white, width: 1.5),
      ),
      child: selected
          ? const Icon(Icons.check, color: Colors.white, size: 14)
          : null,
    );
  }
}

/// Semi-transparent dark format pill for the 全部 view (视频 / LIVE / GIF).
class _TranslucentBadge extends StatelessWidget {
  const _TranslucentBadge({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (label == '视频') ...[
            const Icon(Icons.play_arrow, color: Colors.white, size: 11),
            const SizedBox(width: 1),
          ],
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Post row for the 帖子 list layout: 76px local thumbnail, platform tag +
/// author, title, file count + saved time, and two row actions.
class ListPostRow extends StatelessWidget {
  const ListPostRow({
    super.key,
    required this.record,
    required this.onTap,
    required this.onReparse,
    required this.onOpenOriginal,
    this.selectionMode = false,
    this.selected = false,
    this.onLongPress,
    this.onToggleSelect,
    this.downloadProgress,
    this.downloadPaused = false,
    this.downloadStalled = false,
    this.downloadFailed = false,
    this.downloadFailureReason,
    this.onToggleDownload,
    this.onCancelDownload,
  });

  final HistoryRecord record;
  final VoidCallback onTap;
  final VoidCallback onReparse;
  final VoidCallback onOpenOriginal;
  final bool selectionMode;
  final bool selected;
  final VoidCallback? onLongPress;
  final VoidCallback? onToggleSelect;

  /// 0..1 while a download of this post is running, null otherwise.
  final double? downloadProgress;
  final bool downloadPaused;
  final bool downloadStalled;
  final bool downloadFailed;
  final String? downloadFailureReason;
  final VoidCallback? onToggleDownload;
  final VoidCallback? onCancelDownload;

  @override
  Widget build(BuildContext context) {
    final cover = coverItemFor(record);
    // Items, never files: a Live photo's still and clip are one item, and this
    // number is what the row says (v1.11 build 59).
    final itemCount = savedMediaEntryCount(record.savedFiles);
    final title = (record.title?.isNotEmpty == true) ? record.title! : '无标题';
    final badge = listTypeBadge(cover);

    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTokens.cardRadius),
        onTap: selectionMode ? onToggleSelect : onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              if (selectionMode) ...[
                _RowCheckbox(selected: selected),
                const SizedBox(width: 12),
              ],
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: SizedBox(
                  width: 76,
                  height: 76,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      HistoryThumb(record: record, fit: BoxFit.cover),
                      if (downloadProgress != null)
                        Positioned.fill(
                          child: DownloadingOverlay(
                            progress: downloadProgress!,
                            compact: true,
                            paused: downloadPaused,
                            stalled: downloadStalled,
                          failed: downloadFailed,
                          failureReason: downloadFailureReason,
                          partial: record.savedFiles.isNotEmpty,
                            onTogglePause: selectionMode
                                ? null
                                : onToggleDownload,
                            onCancel: selectionMode ? null : onCancelDownload,
                          ),
                        ),
                      if (badge != null)
                        Positioned(
                          top: 4,
                          left: 4,
                          child: WhiteBadge(label: badge),
                        ),
                      if (itemCount > 1)
                        Positioned(
                          right: 4,
                          bottom: 4,
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.6),
                              shape: BoxShape.circle,
                            ),
                            child: Text(
                              '$itemCount',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            PlatformTag(
                              platform: record.platform,
                              savedDisplayName: record.platformDisplayName,
                            ),
                            AiLabelBadge(
                              text: record.aiLabel,
                              source: record.aiLabelSource,
                            ),
                          ],
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            record.authorName ?? '',
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppTokens.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$itemCount 项 · ${formatSavedAt(record.createdAt)}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppTokens.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              if (!selectionMode) ...[
                const SizedBox(width: 4),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  constraints: const BoxConstraints.tightFor(
                    width: 32,
                    height: 32,
                  ),
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.refresh),
                  tooltip: '重新解析',
                  onPressed: onReparse,
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  constraints: const BoxConstraints.tightFor(
                    width: 32,
                    height: 32,
                  ),
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.open_in_new),
                  tooltip: '打开原帖',
                  onPressed: onOpenOriginal,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _RowCheckbox extends StatelessWidget {
  const _RowCheckbox({required this.selected});
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? AppTokens.primary : Colors.transparent,
        border: Border.all(
          color: selected ? AppTokens.primary : AppTokens.textSecondary,
          width: 1.5,
        ),
      ),
      child: selected
          ? const Icon(Icons.check, color: Colors.white, size: 16)
          : null,
    );
  }
}

/// Single-media card for the 全部 view: pure cover, no title / overlay.
class AllMediaCard extends StatelessWidget {
  const AllMediaCard({
    super.key,
    required this.record,
    required this.itemIndex,
    required this.onTap,
    this.selectionMode = false,
    this.selected = false,
    this.onLongPress,
    this.onToggleSelect,
  });

  final HistoryRecord record;
  final int itemIndex;
  final VoidCallback onTap;
  final bool selectionMode;
  final bool selected;
  final VoidCallback? onLongPress;
  final VoidCallback? onToggleSelect;

  @override
  Widget build(BuildContext context) {
    final item = allMediaItemFor(record, itemIndex);
    final radius = BorderRadius.circular(16);
    final badge = listTypeBadge(item);

    return GestureDetector(
      onTap: selectionMode ? onToggleSelect : onTap,
      onLongPress: onLongPress,
      child: ClipRRect(
        borderRadius: radius,
        child: AspectRatio(
          aspectRatio: aspectRatioFor(item),
          child: Stack(
            fit: StackFit.expand,
            children: [
              HistoryThumb(
                record: record,
                itemIndex: itemIndex,
                fit: BoxFit.cover,
              ),
              if (badge != null)
                Positioned(
                  top: 6,
                  left: 6,
                  child: _TranslucentBadge(label: badge),
                ),
              if (record.visibleFiles.any(
                (f) => f.itemIndex == itemIndex && f.notOriginal,
              ))
                const Positioned(
                  top: 30,
                  left: 6,
                  child: _TranslucentBadge(label: '非原图'),
                ),
              if (record.aiLabel != null)
                Positioned(
                  bottom: 6,
                  left: 6,
                  child: AiLabelBadge(
                    text: record.aiLabel,
                    source: record.aiLabelSource,
                  ),
                ),
              if (selectionMode)
                Positioned(
                  top: 6,
                  right: 6,
                  child: _SelectionDot(selected: selected),
                ),
              if (selectionMode && selected)
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: radius,
                        border: Border.all(
                          color: AppTokens.primary,
                          width: 2.5,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Creator card for the 创作者 view: 2x2 cover grid + name + counts.
class CreatorCard extends StatelessWidget {
  const CreatorCard({
    super.key,
    required this.authorName,
    required this.platform,
    this.savedDisplayName,
    required this.postCount,
    required this.itemCount,
    required this.thumbs,
    required this.onTap,
  });

  final String authorName;
  final String platform;
  final String? savedDisplayName;
  final int postCount;

  /// Items across this creator's posts (a Live photo counts once).
  final int itemCount;
  final List<HistThumbRef> thumbs;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 1,
              crossAxisSpacing: 1,
              children: [
                for (var i = 0; i < 4; i++)
                  _CreatorCell(ref: i < thumbs.length ? thumbs[i] : null),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            authorName.isEmpty ? '未知作者' : authorName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              PlatformTag(
                platform: platform,
                savedDisplayName: savedDisplayName,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  '$postCount 帖 · $itemCount 项',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppTokens.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CreatorCell extends StatelessWidget {
  const _CreatorCell({required this.ref});
  final HistThumbRef? ref;

  @override
  Widget build(BuildContext context) {
    final r = ref;
    if (r == null) {
      return ColoredBox(color: SecondaryBg.beige(context));
    }
    return HistoryThumb(
      record: r.record,
      itemIndex: r.itemIndex,
      fit: BoxFit.cover,
      brokenIconSize: 16,
      // A cell of the 2×2 grid: the small tier, shared with the thumbnail
      // strip and the parse page (v1.11 batch 3).
      thumbnailSize: LocalThumbnailTiers.small,
    );
  }
}
