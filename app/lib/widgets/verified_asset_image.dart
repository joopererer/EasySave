import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';
import '../services/gallery_locator_service.dart';
import '../services/verified_media.dart';

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      setState(() => _exists = _verify());
    }
  }
  @override
  void didUpdateWidget(VerifiedAssetImage old) {
    super.didUpdateWidget(old);
    if (old.asset.id != widget.asset.id) {
      _exists = _verify();
      _failed = false;
    }
  }
  void _invalidate() {
    if (_failed) return;
    _failed = true;
    final id = widget.asset.id;
    VerifiedAssetImage._knownPresent.remove(id);
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
      if (_failed) return widget.fallback;
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
        errorBuilder: (_, _, _) { _invalidate(); return widget.fallback; });
    },
  );
}
