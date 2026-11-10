import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';
import '../services/gallery_locator_service.dart';
import '../services/verified_media.dart';
import 'progressive_asset_image.dart';

class VerifiedAssetImage extends StatefulWidget {
  const VerifiedAssetImage(this.asset, {super.key, required this.fallback,
    this.isOriginal = false, this.thumbnailSize = const ThumbnailSize.square(400),
    this.fit, this.width, this.height, this.verifyExistence,
    this.placeholderColor, this.highResolution});
  final AssetEntity asset;
  final Widget fallback;
  final bool isOriginal;
  final ThumbnailSize thumbnailSize;
  final BoxFit? fit;
  final double? width, height;
  final Future<bool> Function(String)? verifyExistence;

  /// Colour of the cover area before any frame exists; the caller passes the
  /// platform-tinted cover colour so a new cover never shows an empty (black)
  /// rectangle.
  final Color? placeholderColor;

  /// The viewer reports "zoomed past the high-resolution threshold" here; the
  /// original is decoded on demand and released when it goes back to false.
  final ValueListenable<bool>? highResolution;

  /// Test seam for the existence check of an asset.
  @visibleForTesting
  static Future<bool> Function(String id)? existenceForTesting;

  /// Test seam for the decoded image of an asset.
  @visibleForTesting
  static ImageProvider Function(AssetEntity asset, bool isOriginal, ThumbnailSize size)?
      providerForTesting;

  /// The image provider for one tier of an asset. With [screenPixels] an
  /// original is decoded at the screen size instead of its own pixels; the
  /// result is value-equal across rebuilds, so the gallery keeps the same
  /// provider alive and a revisited page reuses the decoded image.
  static ImageProvider providerFor(
    AssetEntity asset, {
    bool isOriginal = false,
    ThumbnailSize thumbnailSize = const ThumbnailSize.square(400),
    Size? screenPixels,
  }) {
    final seam = providerForTesting;
    if (seam != null) return seam(asset, isOriginal, thumbnailSize);
    if (isOriginal && screenPixels != null) {
      return screenSizedAssetProvider(
        asset,
        decodeTargetFor(
          imageWidth: asset.width,
          imageHeight: asset.height,
          screenPixels: screenPixels,
        ),
      );
    }
    return AssetEntityImageProvider(
      asset,
      isOriginal: isOriginal,
      thumbnailSize: thumbnailSize,
    );
  }

  /// The system thumbnail underlay of the fullscreen viewer: same box as the
  /// screen-size decode, served by MediaStore in a few milliseconds.
  static ImageProvider underlayFor(
    AssetEntity asset, {
    required Size screenPixels,
  }) {
    final target = decodeTargetFor(
      imageWidth: asset.width,
      imageHeight: asset.height,
      screenPixels: screenPixels,
    );
    final seam = providerForTesting;
    if (seam != null) {
      return seam(asset, false, ThumbnailSize(target.width.round(),
          target.height.round()));
    }
    return systemThumbnailProvider(asset, target);
  }

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

  /// The sharpest tier this widget asks for in the current build.
  ImageProvider _providerFor(BuildContext context) =>
      VerifiedAssetImage.providerFor(widget.asset,
          isOriginal: widget.isOriginal,
          thumbnailSize: widget.thumbnailSize,
          screenPixels: widget.isOriginal ? screenPixelSize(context) : null);

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
      final provider = _providerFor(context);
      if (snapshot.connectionState == ConnectionState.done && snapshot.data != true) {
        // A decoded thumbnail is display-only: a fresh negative lookup wins.
        PaintingBinding.instance.imageCache.evict(provider);
        return widget.fallback;
      }
      final resolved = snapshot.data == true ||
          PaintingBinding.instance.imageCache.statusForKey(provider).keepAlive;
      if (!resolved) {
        // Still checking and nothing decoded yet: keep the cover area in the
        // placeholder colour instead of an empty rectangle.
        return SizedBox(
          width: widget.width,
          height: widget.height,
          child: ColoredBox(
            color: widget.placeholderColor ??
                Theme.of(context).colorScheme.surfaceContainerHighest,
          ),
        );
      }
      final screen = screenPixelSize(context);
      // A local original of the viewer is decoded at the screen size; the
      // system thumbnail under it makes a swipe show pixels immediately.
      final ImageProvider? underlay = widget.isOriginal
          ? VerifiedAssetImage.underlayFor(widget.asset, screenPixels: screen)
          : null;
      return ProgressiveAssetImage(
        key: ValueKey(widget.asset.id),
        sharp: provider,
        underlay: underlay,
        original: widget.isOriginal
            ? VerifiedAssetImage.providerFor(widget.asset, isOriginal: true)
            : null,
        highResolution: widget.isOriginal ? widget.highResolution : null,
        fit: widget.fit ?? BoxFit.cover,
        width: widget.width,
        height: widget.height,
        placeholderColor: widget.placeholderColor,
        onError: _invalidate,
      );
    },
  );
}
