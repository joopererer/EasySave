// Progressive local-image rendering for covers and the fullscreen browser.
//
// A cover never shows an empty (black) rectangle: the area starts with a
// neutral placeholder, the MediaStore system thumbnail is put underneath as
// soon as it decodes, and the sharp image fades in over [progressiveImageFade]
// once its first frame exists. A frame that is already decoded (cache hit) is
// painted in the same frame without any fade, so list churn (a new post
// pushing the others down) never flashes a cover.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';

/// Cross-fade of a decoded image over its placeholder.
const Duration progressiveImageFade = Duration(milliseconds: 150);

/// Screen size in physical pixels (logical size x devicePixelRatio).
Size screenPixelSize(BuildContext context) {
  final media = MediaQuery.maybeOf(context);
  final dpr = media?.devicePixelRatio ?? 1.0;
  final size = media?.size ?? const Size(1080, 1920);
  return Size(size.width * dpr, size.height * dpr);
}

/// Decode target for an [imageWidth]x[imageHeight] image shown on a screen of
/// [screenPixels]: same aspect ratio, fitted inside the screen, so neither
/// side exceeds the screen and the long side never passes the screen's long
/// side in physical pixels.
Size decodeTargetFor({
  required int imageWidth,
  required int imageHeight,
  required Size screenPixels,
}) {
  final screen = Size(
    screenPixels.width < 1 ? 1 : screenPixels.width,
    screenPixels.height < 1 ? 1 : screenPixels.height,
  );
  if (imageWidth <= 0 || imageHeight <= 0) return screen;
  final fitted = applyBoxFit(
    BoxFit.contain,
    Size(imageWidth.toDouble(), imageHeight.toDouble()),
    screen,
  );
  return Size(
    fitted.destination.width.round().clamp(1, imageWidth).toDouble(),
    fitted.destination.height.round().clamp(1, imageHeight).toDouble(),
  );
}

/// The original bytes decoded at [target] instead of their own size. The
/// provider is value-equal for an equal asset and target, so the image cache
/// and the neighbour pre-decode keep working across rebuilds.
ImageProvider screenSizedAssetProvider(AssetEntity asset, Size target) =>
    ResizeImage(
      AssetEntityImageProvider(asset, isOriginal: true),
      width: target.width.round(),
      height: target.height.round(),
      policy: ResizeImagePolicy.fit,
    );

/// MediaStore system thumbnail (Android `ContentResolver.loadThumbnail`),
/// used as the instant underlay.
ImageProvider systemThumbnailProvider(AssetEntity asset, Size target) =>
    AssetEntityImageProvider(
      asset,
      isOriginal: false,
      thumbnailSize: ThumbnailSize(
        target.width.round().clamp(1, 8192),
        target.height.round().clamp(1, 8192),
      ),
    );

/// Full original, only requested while the viewer is zoomed in.
ImageProvider originalAssetProvider(AssetEntity asset) =>
    AssetEntityImageProvider(asset, isOriginal: true);

/// A local asset rendered as placeholder -> [underlay] -> [sharp] -> optional
/// original ([highResolution]), each tier fading in over [fade].
class ProgressiveAssetImage extends StatefulWidget {
  const ProgressiveAssetImage({
    super.key,
    required this.sharp,
    this.underlay,
    this.original,
    this.highResolution,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.placeholderColor,
    this.fade = progressiveImageFade,
    this.onError,
  });

  /// The tier that is sharp enough for the current context: the system
  /// thumbnail for list covers, the screen-size decode for the viewer.
  final ImageProvider sharp;

  /// Instant, cheap tier drawn under [sharp] (the system thumbnail).
  final ImageProvider? underlay;

  /// Highest tier, only built and decoded while [highResolution] is true.
  final ImageProvider? original;
  final ValueListenable<bool>? highResolution;

  final BoxFit fit;
  final double? width;
  final double? height;
  final Color? placeholderColor;
  final Duration fade;
  final VoidCallback? onError;

  @override
  State<ProgressiveAssetImage> createState() => _ProgressiveAssetImageState();
}

class _ProgressiveAssetImageState extends State<ProgressiveAssetImage> {
  @override
  Widget build(BuildContext context) {
    final placeholder =
        widget.placeholderColor ??
        Theme.of(context).colorScheme.surfaceContainerHighest;
    final highResolution = widget.highResolution;
    final original = widget.original;
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: placeholder),
          if (widget.underlay != null)
            _ProgressiveFrame(
              key: const ValueKey('underlay'),
              provider: widget.underlay!,
              fit: widget.fit,
              fade: widget.fade,
              onError: widget.onError,
            ),
          _ProgressiveFrame(
            key: const ValueKey('sharp'),
            provider: widget.sharp,
            fit: widget.fit,
            fade: widget.fade,
            onError: widget.onError,
          ),
          if (original != null && highResolution != null)
            ValueListenableBuilder<bool>(
              valueListenable: highResolution,
              builder: (context, zoomed, _) {
                if (!zoomed) {
                  // Zoomed back out: drop the original so its pixels leave the
                  // image cache instead of sitting next to the screen-size one.
                  _release(original);
                  return const SizedBox.shrink();
                }
                return _ProgressiveFrame(
                  key: const ValueKey('original'),
                  provider: original,
                  fit: widget.fit,
                  fade: widget.fade,
                  onError: widget.onError,
                );
              },
            ),
        ],
      ),
    );
  }

  void _release(ImageProvider provider) {
    final cache = PaintingBinding.instance.imageCache;
    if (!cache.containsKey(provider)) return;
    cache.evict(provider);
  }
}

/// One decoded tier. Paints the current frame as soon as it exists and fades
/// in when the first frame arrives asynchronously; a frame that is already
/// decoded (synchronous cache hit) is painted without any fade or blank frame.
class _ProgressiveFrame extends StatefulWidget {
  const _ProgressiveFrame({
    super.key,
    required this.provider,
    required this.fit,
    required this.fade,
    this.onError,
  });

  final ImageProvider provider;
  final BoxFit fit;
  final Duration fade;
  final VoidCallback? onError;

  @override
  State<_ProgressiveFrame> createState() => _ProgressiveFrameState();
}

class _ProgressiveFrameState extends State<_ProgressiveFrame> {
  ImageStream? _stream;
  ImageStreamListener? _listener;
  ImageInfo? _info;

  /// The frame came from the image cache in this very frame: no fade.
  bool _instant = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(_ProgressiveFrame old) {
    super.didUpdateWidget(old);
    if (old.provider != widget.provider) {
      _releaseStream();
      _instant = false;
      _resolve();
    }
  }

  void _resolve() {
    if (_stream != null) return;
    final stream = widget.provider.resolve(
      createLocalImageConfiguration(context),
    );
    _stream = stream;
    final listener = ImageStreamListener(
      _handleFrame,
      onError: (error, stack) {
        widget.onError?.call();
      },
    );
    _listener = listener;
    stream.addListener(listener);
  }

  void _handleFrame(ImageInfo info, bool synchronousCall) {
    if (!mounted) {
      info.dispose();
      return;
    }
    final replaced = _info;
    _info = info.clone();
    _instant = synchronousCall;
    // A synchronous call happens inside resolve(): from the image cache on a
    // cache hit, or from the completer set during the first resolve. The build
    // that follows paints it directly, so no setState (and no blank frame).
    if (!synchronousCall) setState(() {});
    replaced?.dispose();
  }

  void _releaseStream() {
    final listener = _listener;
    final stream = _stream;
    if (stream != null && listener != null) stream.removeListener(listener);
    _listener = null;
    _stream = null;
    _info?.dispose();
    _info = null;
  }

  @override
  void dispose() {
    _releaseStream();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    // A cache hit is painted at once; only an asynchronously decoded first
    // frame cross-fades over the placeholder.
    final duration = _instant ? Duration.zero : widget.fade;
    return AnimatedOpacity(
      opacity: info == null ? 0.0 : 1.0,
      duration: duration,
      curve: Curves.easeOut,
      child: RawImage(
        image: info?.image,
        fit: widget.fit,
        filterQuality: FilterQuality.medium,
      ),
    );
  }
}
