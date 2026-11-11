import 'dart:async';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import '../services/gallery_locator_service.dart';
import '../services/media_load_gate.dart';
import '../services/verified_media.dart';
import 'local_asset_image.dart';

/// A local album asset, shown only when the MediaStore still confirms it.
///
/// * The decode goes through [LocalThumbImageProvider] / 
///   [LocalOriginalImageProvider], i.e. through the media load gate: a deadline,
///   its own slot and a `[MediaLoad]` trail.
/// * A *failed* lookup (timeout, saturated plugin queue) is not "deleted": the
///   local thumbnail stays and no network request is started.
/// * With [isOriginal] the system thumbnail is painted first and the original
///   replaces it silently once decoded; a timeout or failure keeps the
///   thumbnail and offers a tap-to-retry, never a permanent grey area.
class VerifiedAssetImage extends StatefulWidget {
  const VerifiedAssetImage(
    this.asset, {
    super.key,
    required this.fallback,
    this.isOriginal = false,
    this.thumbnailSize = const ThumbnailSize.square(400),
    this.fit,
    this.width,
    this.height,
    this.verifyExistence,
    this.scope,
    this.localFailure,
    this.knownBytes,
  });

  final AssetEntity asset;

  /// Shown when the MediaStore positively reports the file as gone.
  final Widget fallback;

  final bool isOriginal;
  final ThumbnailSize thumbnailSize;
  final BoxFit? fit;
  final double? width;
  final double? height;
  final Future<bool> Function(String)? verifyExistence;

  /// Cancels the requests of this row when its page closes.
  final MediaLoadScope? scope;

  /// Shown when the *local* decode fails or times out while the file is known
  /// to be local. Keeps the cover off the network.
  final Widget? localFailure;

  /// MediaStore size of the asset, for sizing the original deadline.
  final int? knownBytes;

  /// Test seam for the existence check of an asset.
  @visibleForTesting
  static Future<bool> Function(String id)? existenceForTesting;

  /// Test seam for the decoded image of an asset.
  @visibleForTesting
  static ImageProvider Function(
    AssetEntity asset,
    bool isOriginal,
    ThumbnailSize size,
  )?
  providerForTesting;

  /// The image provider this widget shows; the gallery keeps the same
  /// provider alive so a revisited page reuses the decoded image.
  static ImageProvider providerFor(
    AssetEntity asset, {
    bool isOriginal = false,
    ThumbnailSize thumbnailSize = const ThumbnailSize.square(400),
    MediaLoadScope? scope,
    int? knownBytes,
    bool cover = false,
  }) =>
      providerForTesting?.call(asset, isOriginal, thumbnailSize) ??
      (isOriginal
          ? LocalOriginalImageProvider(asset, scope: scope, knownBytes: knownBytes)
          : LocalThumbImageProvider(
              asset,
              thumbnailSize,
              scope: scope,
              cover: cover,
            ));

  /// Assets confirmed present in this session; a revisited page renders
  /// at once instead of waiting for another existence check.
  static final Set<String> _knownPresent = {};

  /// Assets confirmed gone; those go straight to [fallback].
  static final Set<String> _knownAbsent = {};

  @visibleForTesting
  static void resetKnownPresentForTesting() {
    _knownPresent.clear();
    _knownAbsent.clear();
  }

  @override
  State<VerifiedAssetImage> createState() => _VerifiedAssetImageState();
}

class _VerifiedAssetImageState extends State<VerifiedAssetImage>
    with WidgetsBindingObserver {
  late Future<MediaExistence> _existence = _verify();
  MediaLoadScope? _ownScope;
  bool _originalFailed = false;
  bool _thumbFailed = false;
  int _attempt = 0;

  MediaLoadScope get _scope =>
      widget.scope ?? (_ownScope ??= MediaLoadScope('row:${widget.asset.id}'));

  Future<MediaExistence> _verify() async {
    final id = widget.asset.id;
    final override =
        widget.verifyExistence ?? VerifiedAssetImage.existenceForTesting;
    final MediaExistence state;
    if (override != null) {
      state = await override(id)
          ? MediaExistence.present
          : MediaExistence.absent;
    } else {
      state = await mediaExistence(id);
    }
    if (state == MediaExistence.present) {
      VerifiedAssetImage._knownPresent.add(id);
      VerifiedAssetImage._knownAbsent.remove(id);
    } else if (state == MediaExistence.absent) {
      VerifiedAssetImage._knownPresent.remove(id);
      VerifiedAssetImage._knownAbsent.add(id);
    }
    // A lookup that did not settle changes nothing: the local thumbnail stays.
    return state;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ownScope?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      setState(() => _existence = _verify());
    }
  }

  @override
  void didUpdateWidget(VerifiedAssetImage old) {
    super.didUpdateWidget(old);
    if (old.asset.id != widget.asset.id) {
      _existence = _verify();
      _originalFailed = false;
      _thumbFailed = false;
      _attempt++;
    }
  }

  void _retry() {
    PaintingBinding.instance.imageCache.evict(
      VerifiedAssetImage.providerFor(
        widget.asset,
        isOriginal: true,
        scope: _scope,
        knownBytes: widget.knownBytes,
      ),
    );
    setState(() {
      _originalFailed = false;
      _thumbFailed = false;
      _attempt++;
    });
  }

  Widget _localFailure(BuildContext context) =>
      widget.localFailure ?? const SizedBox.shrink();

  Widget _thumb(BuildContext context) => Image(
    key: ValueKey('thumb:${widget.asset.id}:$_attempt'),
    image: VerifiedAssetImage.providerFor(
      widget.asset,
      thumbnailSize: widget.thumbnailSize,
      scope: _scope,
      cover: !widget.isOriginal,
    ),
    fit: widget.fit,
    width: widget.width,
    height: widget.height,
    gaplessPlayback: true,
    errorBuilder: (context, error, stack) {
      if (!_thumbFailed) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || _thumbFailed) return;
          _thumbFailed = true;
          GalleryLocatorService.instance.markUnreadable(widget.asset.id);
          setState(() {});
        });
      }
      return _localFailure(context);
    },
  );

  Widget _original(BuildContext context) => Image(
    key: ValueKey('orig:${widget.asset.id}:$_attempt'),
    image: VerifiedAssetImage.providerFor(
      widget.asset,
      isOriginal: true,
      scope: _scope,
      knownBytes: widget.knownBytes,
    ),
    fit: widget.fit,
    width: widget.width,
    height: widget.height,
    gaplessPlayback: true,
    // Paint nothing until the original has a frame: the system thumbnail
    // underneath stays visible, with no loading indicator.
    frameBuilder: (context, child, frame, wasSynchronouslyLoaded) =>
        wasSynchronouslyLoaded || frame != null ? child : const SizedBox.shrink(),
    errorBuilder: (context, error, stack) {
      if (!_originalFailed) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_originalFailed) setState(() => _originalFailed = true);
        });
      }
      return const SizedBox.shrink();
    },
  );

  Widget _retryChip() => Padding(
    padding: const EdgeInsets.all(12),
    child: Material(
      color: Colors.black.withValues(alpha: 0.62),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: _retry,
        borderRadius: BorderRadius.circular(20),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Text(
            '原图加载失败，点击重试',
            style: TextStyle(color: Colors.white, fontSize: 13),
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => FutureBuilder<MediaExistence>(
    future: _existence,
    initialData: VerifiedAssetImage._knownPresent.contains(widget.asset.id)
        ? MediaExistence.present
        : VerifiedAssetImage._knownAbsent.contains(widget.asset.id)
        ? MediaExistence.absent
        : null,
    builder: (context, snapshot) {
      if (snapshot.data == MediaExistence.absent) {
        // A decoded thumbnail is display-only: a fresh positive-negative lookup
        // wins, but only when the MediaStore actually answered.
        PaintingBinding.instance.imageCache.evict(
          VerifiedAssetImage.providerFor(
            widget.asset,
            thumbnailSize: widget.thumbnailSize,
            scope: _scope,
          ),
        );
        return widget.fallback;
      }
      if (!widget.isOriginal) return _thumb(context);
      return Stack(
        fit: StackFit.passthrough,
        alignment: Alignment.center,
        children: [
          _thumb(context),
          _original(context),
          if (_originalFailed) _retryChip(),
        ],
      );
    },
  );
}