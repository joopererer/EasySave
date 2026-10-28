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
  @override
  State<VerifiedAssetImage> createState() => _VerifiedAssetImageState();
}

class _VerifiedAssetImageState extends State<VerifiedAssetImage> with WidgetsBindingObserver {
  late Future<bool> _exists = (widget.verifyExistence ?? mediaExists)(widget.asset.id);
  bool _failed = false;
  AssetEntityImageProvider get _provider => AssetEntityImageProvider(widget.asset,
      isOriginal: widget.isOriginal, thumbnailSize: widget.thumbnailSize);
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
      setState(() => _exists = (widget.verifyExistence ?? mediaExists)(widget.asset.id));
    }
  }
  @override
  void didUpdateWidget(VerifiedAssetImage old) {
    super.didUpdateWidget(old);
    if (old.asset.id != widget.asset.id) {
      _exists = (widget.verifyExistence ?? mediaExists)(widget.asset.id);
      _failed = false;
    }
  }
  void _invalidate() {
    if (_failed) return;
    _failed = true;
    final id = widget.asset.id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      GalleryLocatorService.instance.markUnreadable(id);
      if (mounted && widget.asset.id == id) setState(() {});
    });
  }
  @override
  Widget build(BuildContext context) => FutureBuilder<bool>(
    future: _exists,
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
      return AssetEntityImage(widget.asset, key: ValueKey(widget.asset.id), isOriginal: widget.isOriginal,
        thumbnailSize: widget.thumbnailSize, fit: widget.fit,
        gaplessPlayback: true,
        width: widget.width, height: widget.height,
        errorBuilder: (_, __, ___) { _invalidate(); return widget.fallback; });
    },
  );
}
