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

class _VerifiedAssetImageState extends State<VerifiedAssetImage> {
  late Future<bool> _exists = (widget.verifyExistence ?? mediaExists)(widget.asset.id);
  bool _failed = false;
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      GalleryLocatorService.instance.markUnreadable(widget.asset.id);
      if (mounted) setState(() {});
    });
  }
  @override
  Widget build(BuildContext context) => FutureBuilder<bool>(
    future: _exists,
    builder: (context, snapshot) {
      if (snapshot.data != true || _failed) return widget.fallback;
      return AssetEntityImage(widget.asset, isOriginal: widget.isOriginal,
        thumbnailSize: widget.thumbnailSize, fit: widget.fit,
        width: widget.width, height: widget.height,
        errorBuilder: (_, __, ___) { _invalidate(); return widget.fallback; });
    },
  );
}
