// Unified fullscreen browser component for both PreviewPage (remote mode)
// and HistoryPage / Recent list (local album mode).
// Adheres strictly to docs/design/ui-spec.md and docs/design/gallery-prototype/.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../core/models.dart';
import '../core/dev_log.dart';
import '../core/media_request.dart';
import '../services/gallery_locator_service.dart';
import '../services/history_db.dart';
import '../services/live_pairs.dart';
import '../services/media_delete_service.dart';
import '../services/preview_video.dart';
import '../services/media_request_policy.dart';
import 'shared.dart';
import 'decoded_image_keeper.dart';
import 'verified_asset_image.dart';
import 'ai_label_badge.dart';

class GalleryBrowserItem {
  GalleryBrowserItem({
    required this.index,
    required this.type,
    required this.url,
    this.videoUrl,
    this.posterUrl,
    this.thumbnailUrl,
    this.fallbacks = const [],
    this.requestResources,
    this.isGif = false,
    this.asset,
    this.liveVideoAsset,
    this.status = FileStatus.found,
    this.missing = false,
    this.filename,
    this.cachePostId,
    this.cacheItemIndex,
    this.undecodable = false,
  });

  factory GalleryBrowserItem.fromMediaItem(
    MediaItem item, {
    required int index,
    String? cachePostId,
    AssetEntity? asset,
    AssetEntity? liveVideoAsset,
    FileStatus status = FileStatus.found,
    bool missing = false,
    String? filename,
  }) => GalleryBrowserItem(
    index: index,
    type: item.type,
    url: item.url,
    videoUrl: item.videoUrl,
    posterUrl: item.posterUrl,
    thumbnailUrl: item.thumbnailUrl,
    fallbacks: item.fallbacks,
    requestResources: item.requestResources,
    isGif: item.isGif ?? false,
    cachePostId: cachePostId ?? item.cachePostId,
    cacheItemIndex: item.cacheItemIndex ?? index,
    asset: asset,
    liveVideoAsset: liveVideoAsset,
    status: status,
    missing: missing,
    filename: filename ?? item.localFilename,
  );

  final int index;
  final String type; // 'image', 'video', 'live'
  final String url;
  final String? videoUrl;
  final String? posterUrl;
  final String? thumbnailUrl;

  /// Alternative image URLs (mirrors [MediaItem.fallbacks]); without these the
  /// fullscreen viewer and bottom strip fall back to a single URL and show a
  /// broken image whenever the primary CDN host drops the request.
  final List<String> fallbacks;
  final List<MediaRequestResource>? requestResources;
  final bool isGif;
  final AssetEntity? asset;
  final AssetEntity? liveVideoAsset;
  final FileStatus status;

  /// The album answered and this item is not on the device any more ("不在本机").
  ///
  /// A separate flag on purpose: the post may still carry a network URL for the
  /// item, and a missing file must show the placeholder instead of quietly
  /// falling back to the CDN (v1.11 batch 4).
  final bool missing;
  final String? filename;
  final String? cachePostId;
  final int? cacheItemIndex;

  /// This device cannot decode the saved still (a HEIC with an alpha
  /// auxiliary image on Android 12). The page then offers a replacement
  /// instead of trying to draw a file the platform rejects.
  final bool undecodable;

  /// Build the [MediaItem] that drives [CoverImage] with the full URL set.
  MediaItem toMediaItem() =>
      MediaItem(
          type: type,
          url: url,
          videoUrl: videoUrl,
          posterUrl: posterUrl,
          thumbnailUrl: thumbnailUrl,
          isGif: isGif,
          fallbacks: fallbacks,
          requestResources: requestResources,
        )
        ..cachePostId = cachePostId
        ..cacheItemIndex = cacheItemIndex ?? index;
}

/// Initial selection of the browser. [selectedIndices] holds original post
/// item indices ([GalleryBrowserItem.index]); null means nothing is selected.
Set<int> initialGallerySelection(Set<int>? selectedIndices) =>
    Set<int>.from(selectedIndices ?? const <int>{});

/// Where the page in view sits: inside this browser, and inside the post.
///
/// The browser's own numbering counts what it shows — items on this device and
/// the "不在本机" placeholders — so a delete shrinks it at once. The post's
/// numbering never moves: it is where the item sits in the original post, which
/// is what makes `1 / 3  2 / 8` useful after the first picture was deleted.
/// Both are always shown, even when they agree: the post's place is what the
/// user came for, so hiding it would only make the two numbers appear and
/// disappear as pages change.
class BrowserPosition {
  const BrowserPosition({
    required this.position,
    required this.total,
    required this.postPosition,
    required this.postTotal,
  });

  /// 1-based place of the page in this browser.
  final int position;

  /// How many items this browser shows.
  final int total;

  /// 1-based place of the item in the post; null when the post no longer has
  /// that place (a re-parse came back with fewer items than the stored index).
  final int? postPosition;

  /// The post's item total as last parsed.
  final int postTotal;

  /// The post's numbering is always shown: the pill on the right of the
  /// counter reads `2 / 8`, or `— / 8` when the post no longer reaches the
  /// item's place.
  String get label => '$position / $total';

  String get originLabel => '${postPosition?.toString() ?? '—'} / $postTotal';

  /// Both numbers as one string (semantics only), e.g. `1 / 3  2 / 8`.
  String get fullLabel => '$label  $originLabel';
}

/// The two numbering systems of one viewer page (v1.11 batch 6).
///
/// [listIndex] and [listLength] are the page's place and the browser's item
/// count; [itemIndex] is the item's own 0-based index in the post and
/// [postTotal] the post's item total (a Live photo counts once). A stored index
/// the post no longer reaches keeps the place empty instead of guessing.
BrowserPosition browserPositionFor({
  required int listIndex,
  required int listLength,
  required int itemIndex,
  required int postTotal,
}) {
  final total = listLength < 1 ? 1 : listLength;
  var position = listIndex + 1;
  if (position < 1) position = 1;
  if (position > total) position = total;

  final origin = postTotal < 1 ? 1 : postTotal;
  final postPosition = itemIndex >= 0 && itemIndex < origin ? itemIndex + 1 : null;
  return BrowserPosition(
    position: position,
    total: total,
    postPosition: postPosition,
    postTotal: origin,
  );
}

/// What a re-download changed: what the viewer shows now, and — when the post
/// was parsed again — its new total, so the counter's post numbering follows.
class GalleryBrowserRefresh {
  const GalleryBrowserRefresh({required this.items, this.postTotal});

  final List<GalleryBrowserItem> items;
  final int? postTotal;
}

/// What deleting one item of a post did, so the viewer can say it and offer the
/// undo that "仅删除记录" supports.
class GalleryBrowserItemDeletion {
  const GalleryBrowserItemDeletion({
    required this.ok,
    this.message,
    this.undo,
  });

  /// The change was written (or the album deletion was confirmed).
  final bool ok;

  /// Short user-facing sentence (e.g. that the album file was kept).
  final String? message;

  /// Restores the records the deletion removed. Null when the deletion cannot
  /// be undone (an album file already went to the system trash).
  final Future<void> Function()? undo;
}

/// Locates the album asset behind one stored history row.
typedef HistoryAssetLocator = Future<AssetEntity?> Function(HistoryFile file);

/// Fullscreen browser items for one saved post, plus the page to open.
///
/// The history page and the "最近保存" list both build from here: a Live
/// photo's still and motion clip are one entry ([pairSavedMedia]), shown as one
/// page with the LIVE badge and long-press playback, never as two duplicates.
Future<({List<GalleryBrowserItem> items, int initial})> savedBrowserItems({
  required HistoryRecord record,
  required List<HistoryFile> files,
  required ParsedPost post,
  int? highlightItemIndex,
  HistoryAssetLocator? locate,
  bool? albumScanned,
}) async {
  final entries = pairSavedMedia(files);
  if (entries.isEmpty) {
    return (items: <GalleryBrowserItem>[], initial: 0);
  }

  final locator = GalleryLocatorService.instance;
  final resolver =
      locate ??
      (HistoryFile file) async {
        var asset =
            locator.getAssetById(file.mediaId) ??
            locator.locateAsset(file, record.postId);
        if (asset == null && locator.hasAccess) {
          asset = await locator.locateAssetAsync(
            file,
            record.postId,
            platform: record.platform,
          );
        }
        return asset;
      };
  final scanned = albumScanned ?? (locate == null && locator.scanned);
  final is1Based = files.every((f) => f.itemIndex > 0);

  final items = <GalleryBrowserItem>[];
  var initial = 0;
  for (final entry in entries) {
    final rawIndex = entry.itemIndex;
    final zeroBased = is1Based ? rawIndex - 1 : rawIndex;
    MediaItem? postItem;
    if (zeroBased >= 0 && zeroBased < post.items.length) {
      postItem = post.items[zeroBased];
    } else if (rawIndex >= 0 && rawIndex < post.items.length) {
      postItem = post.items[rawIndex];
    }

    final imageAsset = entry.image == null ? null : await resolver(entry.image!);
    final videoAsset = entry.video == null ? null : await resolver(entry.video!);

    // "不在本机" is only ever read from a row the album already confirmed as
    // gone. A row whose lookup merely failed (no permission, no scan) keeps its
    // status, so an unanswered album never turns an item into a missing one.
    // A Live photo counts as missing when **either** half is: the pair cannot
    // be viewed or re-downloaded by halves.
    final imageMissing = entry.image != null &&
        imageAsset == null &&
        isMissingHistoryFile(entry.image!);
    final videoMissing = entry.video != null &&
        videoAsset == null &&
        isMissingHistoryFile(entry.video!);
    final missing = imageMissing || videoMissing;

    if (highlightItemIndex != null &&
        (rawIndex == highlightItemIndex || zeroBased == highlightItemIndex)) {
      initial = items.length;
    }

    final coverAsset = entry.isLive ? imageAsset : (entry.image == null ? videoAsset : imageAsset);
    final coverFile = entry.cover;
    final fallbackType = coverFile.isImage
        ? 'image'
        : (postItem?.isGif == true ? 'gif' : 'video');
    final itemType = entry.isLive
        ? 'live'
        : (postItem != null && postItem.type != 'live'
              ? postItem.type
              : fallbackType);

    items.add(
      GalleryBrowserItem(
        index: zeroBased,
        cachePostId: record.postId,
        type: itemType,
        url: postItem?.url ?? '',
        videoUrl: postItem?.videoUrl,
        posterUrl: postItem?.posterUrl,
        thumbnailUrl: postItem?.thumbnailUrl,
        fallbacks: postItem?.fallbacks ?? const [],
        requestResources: postItem?.requestResources,
        isGif: postItem?.isGif ?? false,
        asset: coverAsset,
        liveVideoAsset: entry.isLive ? videoAsset : null,
        status: missing
            ? FileStatus.notFound
            : (coverAsset != null
                  ? FileStatus.found
                  : (scanned ? coverFile.status : FileStatus.unknown)),
        missing: missing,
        filename: coverFile.filename,
        undecodable: coverFile.undecodable == true,
      ),
    );
  }
  return (items: items, initial: initial);
}

/// Placeholder for a saved still this device cannot decode.
///
/// The file stays in the album until the user agrees to replace it: the dialog
/// names the file and the reason, and only then is the album deletion asked
/// for. Declining leaves everything untouched.
class _UndecodableView extends StatelessWidget {
  const _UndecodableView({
    required this.item,
    required this.redownloading,
    required this.onRedownload,
  });

  final GalleryBrowserItem item;
  final bool redownloading;
  final Future<void> Function()? onRedownload;

  Future<void> _confirmAndReplace(BuildContext context) async {
    final name = item.filename ?? '该文件';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('本机无法显示此格式'),
        content: Text(
          '相册中的 $name 是这台手机无法解码的图片格式。\n'
          '重新下载会按新规则保存为 JPG 原图，并删除相册里的旧文件。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除并重新下载'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final asset = item.asset;
    if (asset != null) {
      final outcome = await MediaDeleteService.instance.deleteMedia([
        MediaRef(mediaId: asset.id, isImage: true),
      ]);
      if (!outcome.deletedAll && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${outcome.problem ?? '未删除相册中的旧文件'}，仍会下载新文件',
            ),
          ),
        );
      }
    }
    await onRedownload?.call();
  }

  @override
  Widget build(BuildContext context) {
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
              Icons.image_not_supported_outlined,
              color: Colors.white60,
              size: 64,
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            '本机无法显示此格式',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '文件已保存在相册，但这台手机的相册无法预览它',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white54, fontSize: 13),
          ),
          if (onRedownload != null) ...[
            const SizedBox(height: 20),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFF2442),
                foregroundColor: Colors.white,
                shape: const StadiumBorder(),
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 10,
                ),
              ),
              onPressed: redownloading
                  ? null
                  : () => _confirmAndReplace(context),
              icon: redownloading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.download, size: 18),
              label: Text(redownloading ? '下载中...' : '重新下载'),
            ),
          ],
        ],
      ),
    );
  }
}

class GalleryBrowserPage extends StatefulWidget {
  const GalleryBrowserPage({
    super.key,
    required this.items,
    this.initialIndex = 0,
    required this.authorName,
    required this.title,
    required this.platform,
    required this.postUrl,
    this.originalTotal,
    this.deletedIndices = const <int>{},
    this.selectedIndices,
    this.onSelectionChanged,
    this.onRedownload,
    this.onRedownloadItems,
    this.onDeleteItem,
    this.onDeletePost,
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

  /// How many media items the post had when it was parsed. The counter reads
  /// "position / total" — the item's own place in the post, not its place in
  /// this list — minus the items the user deleted ([deletedIndices]).
  /// Null keeps the number of [items] (a remote preview shows them all).
  final int? originalTotal;

  /// Original post item indices the user already deleted in the app, so the
  /// counter opens with the shrunk total instead of the post's old one.
  final Set<int> deletedIndices;
  final Set<int>? selectedIndices;
  final ValueChanged<Set<int>>? onSelectionChanged;

  /// Legacy single-item re-download, addressed by the item's original index.
  final Future<void> Function(int index)? onRedownload;

  /// Preferred re-download entry: asks the caller to re-parse the post and open
  /// the selection panel with exactly these items preselected. Returning a new
  /// item list replaces what the viewer shows, so the state updates in place.
  final Future<GalleryBrowserRefresh?> Function(Set<int> indices)?
      onRedownloadItems;

  /// Deletes one item of the post (v1.11 batch 4). Null hides the action.
  final Future<GalleryBrowserItemDeletion?> Function(
    GalleryBrowserItem item, {
    required bool deleteAlbumFiles,
  })? onDeleteItem;

  /// Called when every remaining item of the post has been deleted and the user
  /// agrees to drop the post record as well.
  final Future<void> Function()? onDeletePost;
  final VoidCallback? onReparse;

  /// When opened from the parse-preview flow, shows a 保存 button that closes
  /// the viewer with `true` so the caller can start the save.
  final bool showSave;

  @override
  State<GalleryBrowserPage> createState() => _GalleryBrowserPageState();
}

class _GalleryBrowserPageState extends State<GalleryBrowserPage> {
  /// The pages shown right now. A delete or a re-download replaces this, so the
  /// viewer updates in place instead of asking the user to open the post again.
  late List<GalleryBrowserItem> _items = List<GalleryBrowserItem>.of(
    widget.items,
  );
  late int _currentIndex = widget.initialIndex;
  late final PageController _pageController = PageController(
    initialPage: widget.initialIndex,
  );
  late final ScrollController _thumbController = ScrollController();
  // Selection is keyed by GalleryBrowserItem.index (the original post item
  // index), never by list position. Viewers that do not drive a selection
  // (history) start with nothing selected.
  late final Set<int> _selected = initialGallerySelection(
    widget.selectedIndices,
  );

  /// A re-download or a delete is running; the buttons stay disabled.
  bool _busy = false;

  /// Original post item indices the current post lost to the user's deletes.
  /// Kept apart from [_items] because a deleted item leaves the viewer: the
  /// post's fallback total only stays right if we remember what is no longer
  /// there.
  late final Set<int> _deleted = {
    for (final index in widget.deletedIndices)
      if (index >= 0) index,
  };

  /// The post's item total a re-parse reported, null until one succeeds.
  int? _parsedPostTotal;

  /// Original post item index of the page in view.
  int? get _currentItemIndex {
    if (_items.isEmpty) return null;
    final i = _currentIndex.clamp(0, _items.length - 1);
    return _items[i].index;
  }

  GalleryBrowserItem? get _currentItem {
    if (_items.isEmpty) return null;
    return _items[_currentIndex.clamp(0, _items.length - 1)];
  }

  /// Items the album confirmed as gone. A Live photo whose still or motion clip
  /// is gone counts once, because the pair is re-downloaded whole.
  List<int> get _missingIndices => [
    for (final item in _items)
      if (item.missing) item.index,
  ];

  /// The post's item total as last known: the total a re-parse reported, else
  /// the record's, else — for a record written before it was stored — what the
  /// viewer holds plus what was deleted from it (the old fallback, unchanged).
  int get _postTotal {
    final parsed = _parsedPostTotal;
    if (parsed != null && parsed > 0) return parsed;
    final declared = widget.originalTotal;
    if (declared != null && declared > 0) return declared;
    final living = _items.length + _deleted.length;
    return living == 0 ? 1 : living;
  }

  /// "1/3 (2/8)": the page's place in this browser, then its place in the post.
  BrowserPosition get _position => browserPositionFor(
    listIndex: _items.isEmpty ? 0 : _currentIndex.clamp(0, _items.length - 1),
    listLength: _items.length,
    itemIndex: _currentItemIndex ?? 0,
    postTotal: _postTotal,
  );

  /// Re-download [indices]: the caller re-parses the post and opens the preview
  /// selection with exactly those items ticked. The refreshed items replace what
  /// this viewer shows, so the counts and placeholders update in place.
  Future<void> _redownload(Set<int> indices) async {
    if (indices.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      final refresh = widget.onRedownloadItems;
      if (refresh != null) {
        final rebuilt = await refresh(indices);
        if (rebuilt != null && mounted) _replaceItems(rebuilt);
        return;
      }
      for (final index in indices) {
        await widget.onRedownload?.call(index);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Ask how the current item should be deleted. Returns false for "仅删除
  /// 记录" (the default), true for "同时删除相册文件", null when cancelled.
  Future<bool?> _askDeleteMode(String title) => showModalBottomSheet<bool>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Text(
              '删除「$title」',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('仅删除记录'),
            subtitle: const Text('相册中的文件保留，可撤销'),
            onTap: () => Navigator.of(sheetContext).pop(false),
          ),
          ListTile(
            leading: const Icon(Icons.delete_forever),
            title: const Text('同时删除相册文件'),
            subtitle: const Text('会先请求系统确认，删除后无法撤销'),
            onTap: () => Navigator.of(sheetContext).pop(true),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );

  /// Delete what the bar acts on — the page in view, or every selected item.
  ///
  /// One dialog asks how (record only / album file too) for the whole batch,
  /// then each item goes through the same single-item deletion, so "仅删除记录"
  /// stays undoable and the system dialog for the album files is the same one.
  Future<void> _deleteTargets() async {
    final remove = widget.onDeleteItem;
    if (_targets.isEmpty || remove == null || _busy) return;
    // Remember where every item sits before the first one leaves, so an undo
    // can put each of them back exactly where it was.
    final items = [
      for (final item in _targets)
        (item: item, at: _items.indexWhere((it) => it.index == item.index)),
    ];
    final title = items.length == 1
        ? '第 ${_position.position} 项'
        : '已选的 ${items.length} 项';
    final withFile = await _askDeleteMode(title);
    if (withFile == null || !mounted) return;
    setState(() => _busy = true);
    final removed =
        <({GalleryBrowserItem item, int at, GalleryBrowserItemDeletion result})>[];
    var failed = 0;
    try {
      for (final entry in items) {
        if (!mounted) break;
        GalleryBrowserItemDeletion? result;
        try {
          result = await remove(
            entry.item,
            deleteAlbumFiles: withFile,
          );
        } catch (_) {
          result = null;
        }
        if (result == null || !result.ok) {
          failed++;
          continue;
        }
        _removeItem(entry.item.index);
        removed.add((item: entry.item, at: entry.at, result: result));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;

    // Whatever left the viewer cannot stay selected.
    setState(
      () => _selected.removeWhere(
        (index) => !_items.any((item) => item.index == index),
      ),
    );
    widget.onSelectionChanged?.call(_selected);

    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    if (removed.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('删除失败，请重试')));
      return;
    }
    final undos = [
      for (final entry in removed)
        if (entry.result.undo != null) entry.result.undo!,
    ];
    final undoAll = undos.length == removed.length && undos.isNotEmpty
        ? () async {
            for (final undo in undos) {
              await undo();
            }
          }
        : null;
    final message = removed.length == 1
        ? (removed.single.result.message ?? '已删除这张')
        : (failed > 0 ? '已删除 ${removed.length} 项，$failed 项删除失败' : '已删除 ${removed.length} 项');
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 6),
        action: undoAll == null
            ? null
            : SnackBarAction(
                label: '撤销',
                onPressed: () async {
                  await undoAll();
                  if (!mounted) return;
                  for (final entry in removed) {
                    _insertItem(entry.item, entry.at);
                  }
                },
              ),
      ),
    );
    if (_items.isEmpty) await _askDeletePost();
  }

  void _removeItem(int index) {
    final at = _items.indexWhere((it) => it.index == index);
    if (at < 0) return;
    setState(() {
      _deleted.add(index);
      _items.removeAt(at);
      _currentIndex = _items.isEmpty
          ? 0
          : (at >= _items.length ? _items.length - 1 : at);
    });
    if (_items.isNotEmpty && _pageController.hasClients) {
      _pageController.jumpToPage(_currentIndex);
    }
  }

  void _insertItem(GalleryBrowserItem item, int at) {
    if (_items.any((it) => it.index == item.index)) return;
    setState(() {
      _deleted.remove(item.index);
      final position = at < 0 || at > _items.length ? _items.length : at;
      _items.insert(position, item);
      _currentIndex = position;
    });
    if (_pageController.hasClients) _pageController.jumpToPage(_currentIndex);
  }

  /// Nothing of the post is left: offer to drop the record as well.
  Future<void> _askDeletePost() async {
    final agreed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('这个帖子已经全部删除'),
        content: const Text('帖子里的媒体都已删除，是否同时删除整条历史记录？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('保留记录'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除记录'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (agreed == true) await widget.onDeletePost?.call();
    if (mounted) Navigator.of(context).pop();
  }

  /// Swap the visible pages, keeping the page the user was looking at.
  void _replaceItems(GalleryBrowserRefresh rebuilt) {
    final keep = _currentItemIndex;
    final keepSelection = Set<int>.of(_selected);
    setState(() {
      _items = List<GalleryBrowserItem>.of(rebuilt.items);
      final parsed = rebuilt.postTotal;
      if (parsed != null && parsed > 0) _parsedPostTotal = parsed;
      final at = keep == null
          ? -1
          : _items.indexWhere((item) => item.index == keep);
      _currentIndex = at >= 0
          ? at
          : (_currentIndex.clamp(0, _items.isEmpty ? 0 : _items.length - 1));
      _selected
        ..clear()
        ..addAll(keepSelection.where((i) => _items.any((it) => it.index == i)));
    });
    if (_pageController.hasClients && _items.isNotEmpty) {
      _pageController.jumpToPage(_currentIndex);
    }
  }

  double _dragOffset = 0.0;
  bool _isZoomed = false;
  int _pointerCount = 0;
  Offset? _dragStart;
  bool _isPullDownActive = false;

  /// Decoded local originals of this session: the current page, its
  /// neighbours and the last pages seen.
  final _decoded = DecodedImageKeeper(capacity: 5);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _keepDecodedAround(_currentIndex);
  }

  /// Decode the current local image and the one or two next to it, and keep
  /// them, so swiping back and forth never decodes a seen image again.
  void _keepDecodedAround(int index) {
    final configuration = createLocalImageConfiguration(context);
    for (final i in [index, index + 1, index - 1]) {
      if (i < 0 || i >= _items.length) continue;
      final item = _items[i];
      final asset = item.asset;
      if (asset == null || item.type == 'video' || item.isGif) continue;
      _decoded.keep(VerifiedAssetImage.providerFor(asset, isOriginal: true), configuration);
    }
  }

  @override
  void dispose() {
    _decoded.dispose();
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

  /// A selection turns every action into "this, for all of them" (v1.11 batch
  /// 6): the bar never needs a second row of buttons.
  bool get _selectionMode => _selected.isNotEmpty;

  /// What the bar acts on: the selected items, or the page in view.
  List<GalleryBrowserItem> get _targets {
    if (_selected.isEmpty) {
      final item = _currentItem;
      return item == null ? const <GalleryBrowserItem>[] : [item];
    }
    return [
      for (final item in _items)
        if (_selected.contains(item.index)) item,
    ];
  }

  void _selectAll() {
    setState(() {
      _selected
        ..clear()
        ..addAll([for (final item in _items) item.index]);
    });
    widget.onSelectionChanged?.call(_selected);
  }

  void _clearSelection() {
    if (_selected.isEmpty) return;
    setState(_selected.clear);
    widget.onSelectionChanged?.call(_selected);
  }

  /// A compact top-bar tool (全选 / 取消选择): 40 dp wide so the two of them and
  /// the selection circle still fit beside the title on a 320 dp screen.
  Widget _topTool({
    required Key key,
    required String label,
    required IconData icon,
    required VoidCallback onPressed,
  }) => IconButton(
    key: key,
    tooltip: label,
    onPressed: onPressed,
    iconSize: 20,
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints.tightFor(width: 40, height: 40),
    style: IconButton.styleFrom(
      foregroundColor: Colors.white,
      backgroundColor: Colors.white.withValues(alpha: 0.12),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
    icon: Icon(icon, semanticLabel: label),
  );

  /// 重新下载: with a selection, only the selected items are ticked in the
  /// preview that re-parses the post; without one, the post is parsed again
  /// with everything selected, exactly like the old 「重新解析」.
  Future<void> _redownloadFromBar() async {
    if (_selectionMode) {
      await _redownload(Set<int>.of(_selected));
      return;
    }
    widget.onReparse?.call();
  }

  /// Share what the bar acts on: the page in view, or every selected item that
  /// is actually on this device ("不在本机" 的项 cannot leave the phone).
  Future<void> _shareTargets() async {
    final items = _targets;
    if (items.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    final shareable = <XFile>[];
    var offline = 0;
    for (final item in items) {
      final asset = item.asset;
      if (item.missing || asset == null) {
        offline++;
        continue;
      }
      try {
        final file = await asset.file;
        if (file != null && await file.exists()) {
          shareable.add(XFile(file.path));
        } else {
          offline++;
        }
      } catch (_) {
        offline++;
      }
    }
    if (items.length > 1 && offline > 0) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            shareable.isEmpty
                ? '$offline 项不在本机，没有可分享的内容'
                : '$offline 项不在本机，只分享还在的 ${shareable.length} 项',
          ),
        ),
      );
    }
    if (shareable.isEmpty) {
      // Only the network post itself can travel then.
      await SharePlus.instance.share(ShareParams(text: widget.postUrl));
      return;
    }
    await SharePlus.instance.share(
      ShareParams(text: widget.postUrl, files: shareable),
    );
  }

  Future<void> _openOriginal() async {
    final uri = Uri.tryParse(widget.postUrl);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentItem = _items.isNotEmpty
        ? _items[_currentIndex.clamp(0, _items.length - 1)]
        : null;
    final isSelected =
        currentItem != null && _selected.contains(currentItem.index);

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
                  itemCount: _items.length,
                  onPageChanged: (idx) {
                    setState(() {
                      _currentIndex = idx;
                      _isZoomed = false;
                    });
                    _keepDecodedAround(idx);
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
                    final item = _items[idx];
                    return _BrowserItemView(
                      // A replaced list must rebuild the page state, not reuse
                      // the state of whatever item used to sit at this index.
                      key: ValueKey<String>(
                        '${item.index}:${item.asset?.id ?? (item.missing ? 'missing' : 'remote')}',
                      ),
                      item: item,
                      platform: widget.platform,
                      onZoomChanged: (zoomed) {
                        if (_isZoomed != zoomed) {
                          setState(() => _isZoomed = zoomed);
                        }
                      },
                      onRedownload:
                          widget.onRedownload != null ||
                              widget.onRedownloadItems != null
                          ? () => _redownload({item.index})
                          : null,
                      onToggleSelect: () => _toggleSelect(item.index),
                      selectionMode: _selectionMode,
                    );
                  },
                ),

                // 2. Top Bar
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
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
                          icon: const Icon(
                            Icons.close,
                            color: Colors.white,
                            size: 24,
                          ),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                        const SizedBox(width: 8),
                        // Title / Subtitle
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Both numbers, always: `1 / 3` then the post's
                              // own place in a translucent stadium pill. The
                              // pair scales down together on the narrowest
                              // screens so the top bar never overflows.
                              Semantics(
                                container: true,
                                label: _position.fullLabel,
                                child: ExcludeSemantics(
                                  child: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Row(
                                      key: const Key('browser_counter'),
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          _position.label,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 16,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        Container(
                                          key: const Key(
                                            'browser_counter_post',
                                          ),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 2,
                                          ),
                                          decoration: BoxDecoration(
                                            color: Colors.white.withValues(
                                              alpha: 0.12,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              999,
                                            ),
                                          ),
                                          child: Text(
                                            _position.originLabel,
                                            style: const TextStyle(
                                              color: Colors.white70,
                                              fontSize: 12,
                                              fontWeight: FontWeight.normal,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              if (widget.authorName.isNotEmpty ||
                                  widget.title.isNotEmpty)
                                Text(
                                  [
                                    if (widget.authorName.isNotEmpty)
                                      widget.authorName,
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
                        AiLabelBadge(
                          text: widget.aiLabel,
                          source: widget.aiLabelSource,
                        ),
                        // Selection tools: 全选 and 取消选择 only make sense once
                        // something is selected, and they belong next to the
                        // circle that starts the selection.
                        if (_selectionMode) ...[
                          _topTool(
                            key: const Key('select_all'),
                            label: '全选',
                            icon: Icons.select_all,
                            onPressed: _selectAll,
                          ),
                          _topTool(
                            key: const Key('clear_selection'),
                            label: '取消选择',
                            icon: Icons.deselect,
                            onPressed: _clearSelection,
                          ),
                        ],
                        // Checkbox
                        Tooltip(
                          message: isSelected ? '取消选中' : '选中',
                          child: Semantics(
                            button: true,
                            label: isSelected ? '取消选中' : '选中',
                            child: GestureDetector(
                              key: const Key('browser_select_toggle'),
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
                                    color: isSelected
                                        ? Colors.transparent
                                        : Colors.white70,
                                    width: 2,
                                  ),
                                ),
                                child: isSelected
                                    ? const Icon(
                                        Icons.check,
                                        color: Colors.white,
                                        size: 18,
                                      )
                                    : null,
                              ),
                            ),
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
                        if (_items.length > 1)
                          SizedBox(
                            height: 56,
                            child: ListView.builder(
                              controller: _thumbController,
                              scrollDirection: Axis.horizontal,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              itemCount: _items.length,
                              itemBuilder: (context, idx) {
                                final it = _items[idx];
                                final isCur = idx == _currentIndex;
                                final isSel = _selected.contains(it.index);

                                return GestureDetector(
                                  key: Key('thumb_${it.index}'),
                                  onTap: () {
                                    _pageController.animateToPage(
                                      idx,
                                      duration: const Duration(
                                        milliseconds: 250,
                                      ),
                                      curve: Curves.easeInOut,
                                    );
                                  },
                                  // The strip is the fastest way to build a
                                  // selection: long-press ticks an item, and a
                                  // second long-press unticks it.
                                  onLongPress: () => _toggleSelect(it.index),
                                  child: Container(
                                    width: 44,
                                    height: 44,
                                    margin: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                      vertical: 6,
                                    ),
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: isCur
                                            ? Colors.white
                                            : Colors.transparent,
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
                        _BrowserActionBar(
                          selectionCount: _selected.length,
                          missingCount: _missingIndices.length,
                          showSave: widget.showSave,
                          busy: _busy,
                          onRedownloadMissing:
                              widget.onRedownloadItems != null ||
                                  widget.onRedownload != null
                              ? () => _redownload(_missingIndices.toSet())
                              : null,
                          onRedownload:
                              widget.onRedownloadItems != null ||
                                  widget.onRedownload != null ||
                                  widget.onReparse != null
                              ? _redownloadFromBar
                              : null,
                          onDelete:
                              widget.onDeleteItem != null &&
                                  currentItem != null
                              ? _deleteTargets
                              : null,
                          onShare: widget.showSave ? null : _shareTargets,
                          onOpenOriginal: widget.showSave ? null : _openOriginal,
                          // Close the viewer and let the preview page start the
                          // save with the synced selection.
                          onSave: widget.showSave
                              ? () => Navigator.of(context).pop(true)
                              : null,
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

/// What the 「更多」 menu keeps once the bar cannot fit them all.
enum _BrowserMoreAction { openOriginal, redownloadMissing }

/// Bottom action bar of the fullscreen viewer.
///
/// One thing at a time: with nothing selected, every button acts on the page
/// in view; with a selection, every button acts on the whole selection. This is
/// the only row the viewer needs — 「重新下载这张」 leaves with it.
///
/// Every button is [_extent] dp high with the icon and text vertically
/// centered, so the row reads as one line. It never overflows: first the hint
/// goes, then the gaps tighten, then the missing-items button shrinks and
/// finally moves into 「更多」; 分享 is never folded away.
class _BrowserActionBar extends StatelessWidget {
  const _BrowserActionBar({
    required this.selectionCount,
    required this.missingCount,
    required this.showSave,
    required this.busy,
    required this.onRedownloadMissing,
    required this.onRedownload,
    required this.onDelete,
    required this.onShare,
    required this.onOpenOriginal,
    required this.onSave,
  });

  final int selectionCount;
  final int missingCount;
  final bool showSave;
  final bool busy;
  final Future<void> Function()? onRedownloadMissing;
  final Future<void> Function()? onRedownload;
  final Future<void> Function()? onDelete;
  final Future<void> Function()? onShare;
  final VoidCallback? onOpenOriginal;
  final VoidCallback? onSave;

  /// One button slot: 48 dp high, and 48 dp wide keeps four of them side by
  /// side with the hint or the missing-items button on a 320 dp screen.
  static const double _extent = 48;
  static const double _looseGap = 8;
  static const double _tightGap = 2;

  /// The measured width is only an estimate of the rendered one; keep this much
  /// room so a rounding difference can never turn into an overflow.
  static const double _reserve = 12;

  static const TextStyle _hintStyle = TextStyle(color: Colors.white70, fontSize: 13);
  static const TextStyle _missingStyle = TextStyle(fontSize: 12);
  static const TextStyle _saveStyle = TextStyle(color: Colors.white, fontSize: 13);
  static const EdgeInsets _missingPadding = EdgeInsets.symmetric(horizontal: 10);

  static double _textWidth(BuildContext context, String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: Directionality.maybeOf(context) ?? TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }
  @override
  Widget build(BuildContext context) {
    if (showSave) return _saveButtonRow();

    final hintText = selectionCount > 0 ? '已选 $selectionCount 项' : '点右上角选择';
    final hintWidth = _textWidth(context, hintText, _hintStyle);
    final missingLabel = '补下缺失($missingCount)';
    final missingWidth = _textWidth(context, missingLabel, _missingStyle);
    // icon 16 + the 8 dp gap and 20 dp of padding a labelled button adds.
    final missingFullWidth = missingWidth + 44;
    final missingTextWidth = missingWidth + 16;
    final showMissing = missingCount > 0 && onRedownloadMissing != null;
    final iconCount =
        (onRedownload != null ? 1 : 0) +
        (onDelete != null ? 1 : 0) +
        (onShare != null ? 1 : 0);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: SizedBox(
        height: _extent,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final available = constraints.maxWidth;

            double needed({
              required bool hint,
              required bool missingFull,
              required bool missingOnlyText,
              required double slot,
              required double gap,
            }) {
              final widths = <double>[
                if (hint) hintWidth,
                if (showMissing && missingFull) missingFullWidth,
                if (showMissing && missingOnlyText) missingTextWidth,
                ...List<double>.filled(
                  iconCount + 1, // the 「更多」 button is always here
                  slot,
                ),
              ];
              return widths.reduce((a, b) => a + b) +
                  gap * (widths.length - 1);
            }

            bool fits(double width) => width <= available - _reserve;

            // Retreat order: the hint, then the gaps, then the width of the
            // missing-items button, and only then its place in 「更多」.
            final tier =
                fits(needed(hint: true, missingFull: true, missingOnlyText: false, slot: _extent, gap: _looseGap))
                ? 1
                : fits(needed(hint: false, missingFull: true, missingOnlyText: false, slot: _extent, gap: _looseGap))
                ? 2
                : fits(needed(hint: false, missingFull: true, missingOnlyText: false, slot: _extent, gap: _tightGap))
                ? 3
                : fits(needed(hint: false, missingFull: true, missingOnlyText: false, slot: 44, gap: _tightGap))
                ? 4
                : fits(needed(hint: false, missingFull: false, missingOnlyText: true, slot: 44, gap: _tightGap))
                ? 5
                : 6;
            final showHint = tier == 1;
            final missingInMenu = tier == 6;
            final gap = tier >= 5 ? 0.0 : (tier <= 2 ? _looseGap : _tightGap);
            final slot = tier >= 4 ? 44.0 : _extent;

            final trailing = <Widget>[
              if (showMissing && !missingInMenu)
                _missingButton(textOnly: tier >= 5),
              if (onRedownload != null)
                _actionButton(
                  slot: slot,
                  key: const Key('redownload'),
                  badgeKey: const Key('badge_redownload'),
                  label: selectionCount > 0 ? '重新下载选中项' : '重新下载',
                  icon: Icons.refresh,
                  onPressed: () => onRedownload?.call(),
                ),
              if (onDelete != null)
                _actionButton(
                  slot: slot,
                  key: const Key('delete_item'),
                  badgeKey: const Key('badge_delete'),
                  label: selectionCount > 0 ? '删除选中项' : '删除这张',
                  icon: Icons.delete_outline,
                  onPressed: () => onDelete?.call(),
                ),
              if (onShare != null)
                _actionButton(
                  slot: slot,
                  key: const Key('share_item'),
                  badgeKey: const Key('badge_share'),
                  label: selectionCount > 0 ? '分享选中项' : '分享',
                  icon: Icons.share,
                  onPressed: () => onShare?.call(),
                ),
              _moreButton(missingInMenu: missingInMenu),
            ];

            return Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (showHint)
                  Expanded(
                    child: Text(
                      hintText,
                      key: const Key('browser_hint'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _hintStyle,
                    ),
                  )
                else
                  const Spacer(),
                for (var i = 0; i < trailing.length; i++) ...[
                  if (i > 0 && gap > 0) SizedBox(width: gap),
                  trailing[i],
                ],
              ],
            );
          },
        ),
      ),
    );
  }
  /// One round icon action, with the number of selected items in a corner badge
  /// once the button speaks for a selection.
  Widget _actionButton({
    required double slot,
    required Key key,
    required Key badgeKey,
    required String label,
    required IconData icon,
    required VoidCallback onPressed,
  }) {
    final button = IconButton(
      key: key,
      tooltip: label,
      onPressed: busy ? null : onPressed,
      iconSize: 20,
      padding: EdgeInsets.zero,
      constraints: BoxConstraints.tightFor(width: slot, height: _extent),
      style: IconButton.styleFrom(
        backgroundColor: Colors.white.withValues(alpha: 0.12),
        foregroundColor: Colors.white,
        shape: const CircleBorder(),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      icon: Icon(icon, semanticLabel: label),
    );
    if (selectionCount <= 0) return button;
    return SizedBox(
      width: slot,
      height: _extent,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(child: button),
          Positioned(
            top: 2,
            right: 2,
            child: IgnorePointer(
              // Just the number: no plate behind it, so the button underneath
              // stays whole. A shadow keeps it readable over bright pictures.
              child: Container(
                key: badgeKey,
                constraints: const BoxConstraints(minWidth: 16),
                height: 16,
                alignment: Alignment.center,
                child: Text(
                  selectionCount.toString(),
                  maxLines: 1,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    shadows: [Shadow(color: Color(0x8A000000), blurRadius: 3)],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The one action that keeps its words: an icon cannot say "N items are gone".
  Widget _missingButton({required bool textOnly}) => Tooltip(
    message: '补下缺失的 $missingCount 张',
    child: SizedBox(
      height: _extent,
      child: TextButton.icon(
        key: const Key('redownload_missing'),
        style: TextButton.styleFrom(
          backgroundColor: Colors.white.withValues(alpha: 0.12),
          foregroundColor: Colors.white,
          shape: const StadiumBorder(),
          padding: textOnly
              ? const EdgeInsets.symmetric(horizontal: 8)
              : _missingPadding,
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          alignment: Alignment.center,
        ),
        onPressed: busy ? null : () => onRedownloadMissing?.call(),
        icon: textOnly
            ? null
            : const Icon(Icons.cloud_download_outlined, size: 16),
        label: Text(
          '补下缺失($missingCount)',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: _missingStyle,
        ),
      ),
    ),
  );

  Widget _moreButton({required bool missingInMenu}) => PopupMenuButton<_BrowserMoreAction>(
    key: const Key('browser_more'),
    tooltip: '更多操作',
    padding: EdgeInsets.zero,
    color: const Color(0xFF232323),
    // The menu hugs its entries: no 112 dp minimum width and no wide margin on
    // the right of the words.
    constraints: const BoxConstraints(minWidth: 0, maxWidth: 220),
    menuPadding: const EdgeInsets.symmetric(vertical: 4),
    onSelected: (action) {
      switch (action) {
        case _BrowserMoreAction.openOriginal:
          onOpenOriginal?.call();
        case _BrowserMoreAction.redownloadMissing:
          onRedownloadMissing?.call();
      }
    },
    itemBuilder: (context) => [
      if (onOpenOriginal != null)
        _menuItem(_BrowserMoreAction.openOriginal, Icons.open_in_new, '打开原帖'),
      if (missingInMenu && missingCount > 0 && onRedownloadMissing != null)
        _menuItem(
          _BrowserMoreAction.redownloadMissing,
          Icons.cloud_download_outlined,
          '补下缺失($missingCount)',
        ),
    ],
    // A bare vertical ellipsis: the disc behind the icon goes, like the one
    // behind every other icon on the bar.
    child: SizedBox(
      width: _extent/2,
      height: _extent,
      child: Stack(
        alignment: Alignment.center,
        children: [
          const Icon(
            Icons.more_vert,
            size: 20,
            color: Colors.white,
            semanticLabel: '更多操作',
          ),
          if (missingInMenu && missingCount > 0)
            Positioned(
              top: 6,
              right: 6,
              child: Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: Color(0xFFFF2442),
                  shape: BoxShape.circle,
                ),
              ),
            ),
        ],
      ),
    ),
  );

  PopupMenuItem<_BrowserMoreAction> _menuItem(
    _BrowserMoreAction value,
    IconData icon,
    String label,
  ) => PopupMenuItem<_BrowserMoreAction>(
    value: value,
    height: 44,
    padding: const EdgeInsets.only(left: 12, right: 12),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, semanticLabel: label),
        const SizedBox(width: 8),
        Text(label, style: const TextStyle(fontSize: 13)),
      ],
    ),
  );

  /// The remote preview's bar keeps one button: 保存, carrying how many items it
  /// would download.
  Widget _saveButtonRow() {
    final label = selectionCount > 0 ? '保存 ($selectionCount)' : '保存';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: SizedBox(
        height: _extent,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const Spacer(),
            SizedBox(
              height: _extent,
              child: Tooltip(
                message: '保存',
                child: FilledButton.icon(
                  key: const Key('browser_primary_action'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFFF2442),
                    foregroundColor: Colors.white,
                    minimumSize: Size.zero,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    shape: const StadiumBorder(),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    alignment: Alignment.center,
                  ),
                  onPressed: busy || selectionCount == 0 ? null : onSave,
                  icon: const Icon(Icons.download, size: 18),
                  label: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _saveStyle,
                  ),
                ),
              ),
            ),
          ],
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
    if (item.missing || item.status == FileStatus.notFound) {
      return Container(
        color: Colors.grey.shade800,
        child: const Icon(Icons.broken_image, size: 18, color: Colors.white54),
      );
    }
    if (item.asset != null) {
      return VerifiedAssetImage(
        item.asset!,
        fallback: CoverImage(
          item: item.toMediaItem(),
          platform: (platform),
          fit: BoxFit.contain,
        ),
        isOriginal: false,
        thumbnailSize: const ThumbnailSize.square(120),
        fit: BoxFit.cover,
      );
    }
    return CoverImage(
      item: item.toMediaItem(),
      platform: (platform),
      fit: BoxFit.cover,
      cacheWidth: 400,
    );
  }
}

class _BrowserItemView extends StatefulWidget {
  const _BrowserItemView({
    super.key,
    required this.item,
    required this.platform,
    this.onZoomChanged,
    this.onRedownload,
    this.onToggleSelect,
    /// The viewer is in multi-select mode: a short tap on the picture toggles
    /// selection instead of playback controls (a real life photo's long press
    /// still plays the motion clip).
    this.selectionMode = false,
  });

  final GalleryBrowserItem item;
  final String platform;
  final ValueChanged<bool>? onZoomChanged;
  final Future<void> Function()? onRedownload;
  final VoidCallback? onToggleSelect;
  final bool selectionMode;

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

    if (widget.item.status == FileStatus.found ||
        widget.item.url.startsWith('http')) {
      if (widget.item.isGif || widget.item.type == 'video') {
        _initVideo();
      }
    }
  }

  Future<void> _checkAssetExistence() async {
    final a = widget.item.asset;
    if (a != null) {
      try {
        final exists = await GalleryLocatorService.instance.isPresent(a.id);
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
      if (_error == null) {
        unawaited(DevLog.write(
          'PreviewPlayer',
          'event=failed source=local item_kind=${widget.item.type} '
              'type=player_state',
        ));
      }
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
      // A still can never be played as a video. The row's asset must be a
      // movie: when an older file of the same album sequence answered the
      // lookup (an `…_1.jpg` cover next to the new `…_1.mp4`), fall through to
      // the motion clip or the network instead of handing the still to the
      // decoder, which is what produced "播放失败".
      final playableAsset = it.asset != null &&
              (it.type == 'image' || it.asset!.type == AssetType.video)
          ? it.asset
          : null;
      if (playableAsset != null) {
        final f = await playableAsset.file;
        if (f != null && await f.exists()) {
          controller = VideoPlayerController.file(f);
        } else {
          final targetUrl = it.videoUrl ?? it.url;
          controller = await networkPreviewController(
            targetUrl,
            widget.platform,
            item: it.toMediaItem(),
          );
        }
      } else {
        final targetUrl = it.videoUrl ?? it.url;
        controller = await networkPreviewController(
          targetUrl,
          widget.platform,
          item: it.toMediaItem(),
        );
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
      unawaited(DevLog.write(
        'PreviewPlayer',
        'event=failed source=${it.asset == null ? 'network' : 'local'} '
            'asset_kind=${it.asset == null ? '-' : (it.asset!.type == AssetType.image ? 'image' : 'video')} '
            'item_kind=${it.type} type=${playbackFailureType(e)}',
      ));
      if (mounted) {
        setState(() => _error = previewFailureMessage(e, widget.platform));
      }
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
    } catch (error) {
      if (mounted) {
        setState(() => _isLiveHolding = false);
        if (error is MediaPolicyException) {
          ScaffoldMessenger.maybeOf(
            context,
          )?.showSnackBar(const SnackBar(content: Text('该资源地址不在允许范围内')));
        }
      }
    }
  }

  Future<VideoPlayerController> _createPlayerController(String target) async {
    if (target.startsWith('http://') || target.startsWith('https://')) {
      return await networkPreviewController(
        target,
        widget.platform,
        item: widget.item.toMediaItem(),
      );
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

    // 0. Saved but undecodable on this device: a HEIC the platform decoders
    //    reject. Offer the replacement the new rules would have downloaded,
    //    and ask before the old album file is deleted.
    if (it.undecodable) {
      return _UndecodableView(
        item: it,
        redownloading: _redownloading,
        onRedownload: widget.onRedownload == null
            ? null
            : () async {
                setState(() => _redownloading = true);
                try {
                  await widget.onRedownload!();
                } finally {
                  if (mounted) setState(() => _redownloading = false);
                }
              },
      );
    }

    // 1. Missing file: "不在本机" placeholder + [重新下载这张]
    if (it.missing || _isNotFound || it.status == FileStatus.notFound) {
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
              '不在本机',
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 10,
                  ),
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
                label: Text(_redownloading ? '下载中...' : '重新下载这张'),
              ),
            ],
          ],
        ),
      );
    }

    // 2. GIF playback: auto loop, muted, tap to pause/play, GIF badge
    if (it.isGif) {
      final c = _videoController;
      return _withSelectionTap(GestureDetector(
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
                child: Text(
                  '播放失败：$_error',
                  style: const TextStyle(color: Colors.white),
                ),
              )
            else
              const Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),

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
                child: const Icon(
                  Icons.play_arrow,
                  color: Colors.white,
                  size: 36,
                ),
              ),
          ],
        ),
      ));
    }

    // 3. Regular Video playback: starts paused, tap the play button to start
    if (it.type == 'video') {
      final c = _videoController;
      return _withSelectionTap(GestureDetector(
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
                  aspectRatio: c.value.aspectRatio == 0
                      ? 16 / 9
                      : c.value.aspectRatio,
                  child: VideoPlayer(c),
                ),
              )
            else if (_error != null)
              Center(
                child: Text(
                  '播放失败：$_error',
                  style: const TextStyle(color: Colors.white),
                ),
              )
            else
              const Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),

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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
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
      ));
    }

    // 4. Live Photo: static cover + "LIVE" badge + "长按播放实况" + press to play loop
    if (it.type == 'live') {
      final c = _videoController;
      final showVideo = _isLiveHolding && c != null && c.value.isInitialized;

      return _withSelectionTap(GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPressStart: (_) => _startLiveMotion(),
        onLongPressEnd: (_) => _stopLiveMotion(),
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (showVideo)
              Center(
                child: AspectRatio(
                  aspectRatio: c.value.aspectRatio == 0
                      ? 1
                      : c.value.aspectRatio,
                  child: VideoPlayer(c),
                ),
              )
            else
              InteractiveViewer(
                minScale: 1.0,
                maxScale: 4.0,
                child: Center(
                  child: it.asset != null
                      ? VerifiedAssetImage(
                          it.asset!,
                          fallback: CoverImage(
                            item: it.toMediaItem(),
                            platform: (widget.platform),
                            fit: BoxFit.contain,
                            fullResolution: true,
                          ),
                          isOriginal: true,
                          fit: BoxFit.contain,
                        )
                      : Stack(
                          fit: StackFit.passthrough,
                          alignment: Alignment.center,
                          children: [
                            CoverImage(
                              item: it.toMediaItem(),
                              platform: (widget.platform),
                              fit: BoxFit.contain,
                              cacheWidth: 400,
                            ),
                            CoverImage(
                              item: it.toMediaItem(),
                              platform: (widget.platform),
                              fit: BoxFit.contain,
                              fullResolution: true,
                              placeholder: const Center(child: CircularProgressIndicator()),
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 6,
                  ),
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
      ));
    }

    // 5. Standard Image: Zoomable with double-tap zoom & pinch pan
    return _withSelectionTap(
      _ZoomableImageView(
        item: it,
        platform: widget.platform,
        onZoomChanged: widget.onZoomChanged,
        onLongPress: widget.onToggleSelect,
      ),
    );
  }

  /// While the viewer is in multi-select mode a tap on the picture toggles the
  /// selection of the page in view — the only thing a tap can mean then. The
  /// pictures below keep their own gestures (long press, zoom, playback), so
  /// this sits on top instead of fighting them in the gesture arena.
  Widget _withSelectionTap(Widget child) {
    if (!widget.selectionMode) return child;
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onToggleSelect,
          ),
        ),
      ],
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
  late final AnimationController _animController;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
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

    final animation =
        Matrix4Tween(
          begin: _transformationController.value,
          end: target,
        ).animate(
          CurvedAnimation(parent: _animController, curve: Curves.easeOutCubic),
        );

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
              ? VerifiedAssetImage(
                  widget.item.asset!,
                  fallback: CoverImage(
                    item: widget.item.toMediaItem(),
                    platform: (widget.platform),
                    fit: BoxFit.contain,
                    fullResolution: true,
                  ),
                  isOriginal: true,
                  fit: BoxFit.contain,
                )
              : Stack(
                  fit: StackFit.passthrough,
                  alignment: Alignment.center,
                  children: [
                    CoverImage(
                      item: widget.item.toMediaItem(),
                      platform: (widget.platform),
                      fit: BoxFit.contain,
                      cacheWidth: 400,
                    ),
                    CoverImage(
                      item: widget.item.toMediaItem(),
                      platform: (widget.platform),
                      fit: BoxFit.contain,
                      fullResolution: true,
                      placeholder: const Center(child: CircularProgressIndicator()),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

@Preview(name: 'MoreButton')
Widget previewMoreButton() {
  return GalleryBrowserPage(
    items: [
      GalleryBrowserItem(
        index: 0,
        type: 'image',
        url: 'https://www.example.com/image.jpg',
      ),
    ], authorName: '', title: '', platform: '', postUrl: '',
  );
}