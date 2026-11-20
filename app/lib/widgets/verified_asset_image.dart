import 'dart:async';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';
import '../core/dev_log.dart';
import '../services/gallery_locator_service.dart';
import '../services/local_thumbnail_tiers.dart';
import '../services/thumbnail_diagnostics.dart';
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
    this.isOriginal = false, this.thumbnailSize = LocalThumbnailTiers.medium,
    this.fit, this.width, this.height, this.verifyExistence, this.onFrame,
    this.onFailed});
  final AssetEntity asset;
  final Widget fallback;
  final bool isOriginal;
  final ThumbnailSize thumbnailSize;
  final BoxFit? fit;
  final double? width, height;
  final Future<bool> Function(String)? verifyExistence;

  /// Called once, when the first frame of this thumbnail has painted (v1.11
  /// batch 3). Measurement only: it never changes what the widget draws.
  final VoidCallback? onFrame;

  /// Called when this widget can no longer produce a frame — a decode error, a
  /// deadline that expired, or a file the album no longer holds. The viewer uses
  /// it to keep its placeholder on screen instead of hiding it behind an empty
  /// full-resolution layer (v1.11 batch 3). The widget's own fallback and
  /// timeout behaviour is unchanged.
  final VoidCallback? onFailed;

  /// Test seam for the existence check of an asset.
  @visibleForTesting
  static Future<bool> Function(String id)? existenceForTesting;

  /// Test seam for the decoded image of an asset.
  @visibleForTesting
  static ImageProvider Function(AssetEntity asset, bool isOriginal, ThumbnailSize size)?
      providerForTesting;

  /// Delay before retrying an unanswered or failed local thumbnail (v1.12 build 75).
  @visibleForTesting
  static Duration lateRetryDelay = const Duration(seconds: 20);

  /// The image provider this widget shows; the gallery keeps the same
  /// provider alive so a revisited page reuses the decoded image.
  static ImageProvider providerFor(
    AssetEntity asset, {
    bool isOriginal = false,
    ThumbnailSize thumbnailSize = LocalThumbnailTiers.medium,
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
  bool _lateArrived = false;
  bool _retryAttempted = false;
  Timer? _watchdog;
  Timer? _retryTimer;
  DateTime? _requestStartTime;
  ImageStream? _imageStream;
  ImageStreamListener? _streamListener;
  ImageInfo? _imageInfo;

  /// Diagnostic handle for the current request (v1.11 batch 1). Bookkeeping
  /// only: it never decides what the widget draws.
  ThumbnailRequest? _request;

  String get _thumbKey =>
      '${widget.asset.id}/${widget.isOriginal ? 'original' : 'thumb'}/'
      '${widget.thumbnailSize.width}x${widget.thumbnailSize.height}';

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

  void _listenToStream() {
    if (widget.isOriginal) return;
    _cleanupStream();
    _requestStartTime = DateTime.now();
    try {
      final stream = _provider.resolve(ImageConfiguration.empty);
      _imageStream = stream;
      _streamListener = ImageStreamListener(
        _handleImageFrame,
        onError: _handleImageError,
      );
      stream.addListener(_streamListener!);
    } catch (_) {}
  }

  void _cleanupStream() {
    if (_streamListener != null && _imageStream != null) {
      _imageStream!.removeListener(_streamListener!);
    }
    _streamListener = null;
    _imageStream = null;
  }

  void _handleImageFrame(ImageInfo info, bool synchronousCall) {
    if (!mounted) return;
    final now = DateTime.now();
    if (_retryAttempted && _imageInfo == null) {
      unawaited(DevLog.write(
        'ThumbLoad',
        'event=late_retry key=$_thumbKey result=ok',
      ));
      setState(() {
        _imageInfo = info;
        _timedOut = false;
        _lateArrived = true;
        _frameSeen = true;
      });
      return;
    }
    if (_timedOut) {
      final lateMs = _requestStartTime != null
          ? now.difference(_requestStartTime!).inMilliseconds
          : 0;
      unawaited(DevLog.write(
        'ThumbLoad',
        'event=late_ok key=$_thumbKey late_ms=$lateMs',
      ));
      _retryTimer?.cancel();
      _retryTimer = null;
      setState(() {
        _imageInfo = info;
        _timedOut = false;
        _lateArrived = true;
        _frameSeen = true;
      });
      return;
    }
    _imageInfo = info;
    if (!_frameSeen) {
      _frameSeen = true;
      _watchdog?.cancel();
      ThumbnailDiagnostics.instance.succeeded(_request);
      _request = null;
      widget.onFrame?.call();
    }
  }

  void _handleImageError(Object exception, StackTrace? stackTrace) {
    if (!mounted) return;
    if (_retryAttempted) {
      unawaited(DevLog.write(
        'ThumbLoad',
        'event=late_retry key=$_thumbKey result=fail',
      ));
    }
  }

  void _scheduleRetry() {
    _retryTimer?.cancel();
    _retryTimer = Timer(VerifiedAssetImage.lateRetryDelay, () {
      if (!mounted || _frameSeen || _imageInfo != null || _retryAttempted) return;
      _retryAttempted = true;
      _listenToStream();
    });
  }

  /// Starts this item's own deadline. A HEIC the platform rejects can leave the
  /// thumbnail request unanswered; after [kLocalThumbnailTimeout] the card
  /// draws its fallback (network cover or placeholder) instead of an empty box,
  /// and the item is logged. Nothing global is held: the abandoned native call
  /// keeps running and its late frame is adopted via late_ok (v1.12 build 75).
  void _startWatchdog() {
    _watchdog?.cancel();
    _retryTimer?.cancel();
    ThumbnailDiagnostics.instance.abandon(_request);
    _timedOut = false;
    _frameSeen = false;
    final id = widget.asset.id;
    final cached = PaintingBinding.instance.imageCache
        .statusForKey(_provider)
        .keepAlive;
    if (cached) {
      ThumbnailDiagnostics.instance.noteCacheHit();
    } else {
      ThumbnailDiagnostics.instance.noteCacheMiss();
    }
    _request = ThumbnailDiagnostics.instance.begin(_thumbKey);
    _watchdog = Timer(kLocalThumbnailTimeout, () {
      if (!mounted || _frameSeen || _failed) return;
      _timedOut = true;
      ThumbnailDiagnostics.instance.timedOut(
        _request,
        timeout: kLocalThumbnailTimeout,
      );
      _request = null;
      if (mounted && widget.asset.id == id) setState(() {});
      widget.onFailed?.call();
      _scheduleRetry();
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startWatchdog();
    _listenToStream();
  }

  @override
  void dispose() {
    _watchdog?.cancel();
    _retryTimer?.cancel();
    _cleanupStream();
    ThumbnailDiagnostics.instance.abandon(_request);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startWatchdog();
      _listenToStream();
      final exists = _verify();
      setState(() {
        _exists = exists;
      });
    }
  }

  @override
  void didUpdateWidget(VerifiedAssetImage old) {
    super.didUpdateWidget(old);
    if (old.asset.id != widget.asset.id) {
      _exists = _verify();
      _failed = false;
      _imageInfo = null;
      _lateArrived = false;
      _retryAttempted = false;
      _retryTimer?.cancel();
      _startWatchdog();
      _listenToStream();
    }
  }

  void _invalidate() {
    if (_failed) return;
    _failed = true;
    _watchdog?.cancel();
    _retryTimer?.cancel();
    final id = widget.asset.id;
    VerifiedAssetImage._knownPresent.remove(id);
    ThumbnailDiagnostics.instance.failed(_request);
    _request = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      GalleryLocatorService.instance.markUnreadable(id);
      if (mounted && widget.asset.id == id) setState(() {});
      widget.onFailed?.call();
    });
  }

  /// Reports a file the album no longer holds, once the frame that draws the
  /// fallback is done (never during build).
  void _reportMissing() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.onFailed?.call();
    });
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<bool>(
    future: _exists,
    initialData: VerifiedAssetImage._knownPresent.contains(widget.asset.id) ? true : null,
    builder: (context, snapshot) {
      if (_failed) return widget.fallback;
      if (_timedOut && _imageInfo == null) return widget.fallback;
      if (snapshot.connectionState == ConnectionState.done && snapshot.data != true) {
        PaintingBinding.instance.imageCache.evict(_provider);
        ThumbnailDiagnostics.instance.abandon(_request);
        _request = null;
        _reportMissing();
        return widget.fallback;
      }
      if (snapshot.data != true && !PaintingBinding.instance.imageCache.statusForKey(_provider).keepAlive) {
        return SizedBox(width: widget.width, height: widget.height);
      }
      final Widget imageWidget;
      if (_lateArrived && _imageInfo != null) {
        imageWidget = RawImage(
          key: ValueKey('raw-${widget.asset.id}'),
          image: _imageInfo!.image,
          fit: widget.fit,
          width: widget.width,
          height: widget.height,
        );
      } else {
        imageWidget = Image(
          image: _provider,
          key: ValueKey(widget.asset.id),
          fit: widget.fit,
          gaplessPlayback: true,
          width: widget.width,
          height: widget.height,
          frameBuilder: (context, child, frame, wasSync) {
            if (frame != null && !_frameSeen) {
              _frameSeen = true;
              _watchdog?.cancel();
              ThumbnailDiagnostics.instance.succeeded(_request);
              _request = null;
              widget.onFrame?.call();
            }
            return child;
          },
          errorBuilder: (_, _, _) {
            _invalidate();
            return widget.fallback;
          },
        );
      }

      if (_lateArrived) {
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: KeyedSubtree(
            key: ValueKey('late-${widget.asset.id}'),
            child: imageWidget,
          ),
        );
      }
      return imageWidget;
    },
  );
}
