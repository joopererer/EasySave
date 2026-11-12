import 'dart:async';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';
import '../core/dev_log.dart';
import '../services/gallery_locator_service.dart';
import '../services/verified_media.dart';

/// How long one local thumbnail may take before the card draws its fallback.
///
/// Per widget on purpose: a photo_manager call cannot be cancelled from Dart,
/// so waiting is all a timeout can stop. Every item owns its own deadline, and
/// nothing is shared between them — one file that never answers must not hold
/// a slot another file would otherwise use.
const Duration kLocalThumbnailTimeout = Duration(seconds: 5);

class VerifiedAssetImage extends StatefulWidget {
  const VerifiedAssetImage(this.asset, {super.key, required this.fallback,
    this.isOriginal = false, this.thumbnailSize = const ThumbnailSize.square(400),
    this.fit, this.width, this.height, this.verifyExistence});
  final AssetEntity asset;
  final Widget fallback;
  final bool isOriginal;
  final ThumbnailSize thumbnailSize;
  final BoxFit? fit;
  final double? width, height;
  final Future<bool> Function(String)? verifyExistence;

  /// Test seam for the existence check of an asset.
  @visibleForTesting
  static Future<bool> Function(String id)? existenceForTesting;

  /// Test seam for the decoded image of an asset.
  @visibleForTesting
  static ImageProvider Function(AssetEntity asset, bool isOriginal, ThumbnailSize size)?
      providerForTesting;

  /// The image provider this widget shows; the gallery keeps the same
  /// provider alive so a revisited page reuses the decoded image.
  static ImageProvider providerFor(
    AssetEntity asset, {
    bool isOriginal = false,
    ThumbnailSize thumbnailSize = const ThumbnailSize.square(400),
  }) =>
      providerForTesting?.call(asset, isOriginal, thumbnailSize) ??
      AssetEntityImageProvider(asset, isOriginal: isOriginal, thumbnailSize: thumbnailSize);

  /// Assets confirmed present in this session; a revisited page renders
  /// at once instead of waiting for another existence check.
  static final Set<String> _knownPresent = {};

  @visibleForTesting
  static void resetKnownPresentForTesting() => _knownPresent.clear();

  @override
  State<VerifiedAssetImage> createState() => _VerifiedAssetImageState();
}

class _VerifiedAssetImageState extends State<VerifiedAssetImage> with WidgetsBindingObserver {
  late Future<bool> _exists = _verify();
  bool _failed = false;
  bool _frameSeen = false;
  bool _timedOut = false;
  Timer? _watchdog;
  ImageProvider get _provider => VerifiedAssetImage.providerFor(widget.asset,
      isOriginal: widget.isOriginal, thumbnailSize: widget.thumbnailSize);

  Future<bool> _verify() async {
    final id = widget.asset.id;
    final present = await (widget.verifyExistence ??
        VerifiedAssetImage.existenceForTesting ??
        mediaExists)(id);
    if (present) {
      VerifiedAssetImage._knownPresent.add(id);
    } else {
      VerifiedAssetImage._knownPresent.remove(id);
    }
    return present;
  }

  /// Starts this item's own deadline. A HEIC the platform rejects can leave the
  /// thumbnail request unanswered; after [kLocalThumbnailTimeout] the card
  /// draws its fallback (network cover or placeholder) instead of an empty box,
  /// and the item is logged. Nothing global is held: the abandoned native call
  /// keeps running and its late frame is simply ignored.
  void _startWatchdog() {
    _watchdog?.cancel();
    _timedOut = false;
    _frameSeen = false;
    final id = widget.asset.id;
    final watch = Stopwatch()..start();
    _watchdog = Timer(kLocalThumbnailTimeout, () {
      if (!mounted || _frameSeen || _failed) return;
      _timedOut = true;
      unawaited(DevLog.write(
        'ThumbLoad',
        'event=local_decode_failed kind=${widget.isOriginal ? 'original' : 'thumb'} '
            'reason=timeout ms=${watch.elapsedMilliseconds}',
      ));
      if (mounted && widget.asset.id == id) setState(() {});
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startWatchdog();
  }
  @override
  void dispose() {
    _watchdog?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startWatchdog();
      setState(() => _exists = _verify());
    }
  }
  @override
  void didUpdateWidget(VerifiedAssetImage old) {
    super.didUpdateWidget(old);
    if (old.asset.id != widget.asset.id) {
      _exists = _verify();
      _failed = false;
      _startWatchdog();
    }
  }
  void _invalidate() {
    if (_failed) return;
    _failed = true;
    _watchdog?.cancel();
    final id = widget.asset.id;
    VerifiedAssetImage._knownPresent.remove(id);
    unawaited(DevLog.write(
      'ThumbLoad',
      'event=local_decode_failed kind=${widget.isOriginal ? 'original' : 'thumb'} '
          'reason=decode',
    ));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      GalleryLocatorService.instance.markUnreadable(id);
      if (mounted && widget.asset.id == id) setState(() {});
    });
  }
  @override
  Widget build(BuildContext context) => FutureBuilder<bool>(
    future: _exists,
    initialData: VerifiedAssetImage._knownPresent.contains(widget.asset.id) ? true : null,
    builder: (context, snapshot) {
      if (_failed || _timedOut) return widget.fallback;
      if (snapshot.connectionState == ConnectionState.done && snapshot.data != true) {
        // A decoded thumbnail is display-only: a fresh negative lookup wins.
        PaintingBinding.instance.imageCache.evict(_provider);
        return widget.fallback;
      }
      if (snapshot.data != true && !PaintingBinding.instance.imageCache.statusForKey(_provider).keepAlive) {
        // Do not start a CDN image and then replace it with a local image a
        // frame later. On layout switches the decoded local image is reused.
        return SizedBox(width: widget.width, height: widget.height);
      }
      // A local original is decoded straight away. While it decodes the area
      // stays empty: no enlarged thumbnail and no loading indicator, which
      // are reserved for remote previews of files not yet on this device.
      return Image(image: _provider, key: ValueKey(widget.asset.id), fit: widget.fit,
        gaplessPlayback: true,
        width: widget.width, height: widget.height,
        frameBuilder: (context, child, frame, wasSync) {
          if (frame != null && !_frameSeen) {
            _frameSeen = true;
            _watchdog?.cancel();
          }
          return child;
        },
        errorBuilder: (_, _, _) { _invalidate(); return widget.fallback; });
    },
  );
}
