// Image providers for local album assets.
//
// Both providers read through LocalMedia, so every decode has a deadline, a
// pool slot of its own and the log trail the device diagnostic needs:
//   * [LocalThumbImageProvider]  -> thumb pool, 5 s, never the original bytes
//   * [LocalOriginalImageProvider] -> original pool, deadline by file size
//
// A rejected/timed-out/cancelled request surfaces as an error on the provider,
// which the widget turns into "keep the thumbnail, offer a retry" instead of a
// permanent grey area.

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:photo_manager/photo_manager.dart';

import '../services/local_media.dart';
import '../services/media_load_gate.dart';

@immutable
class LocalThumbImageProvider extends ImageProvider<LocalThumbImageProvider> {
  const LocalThumbImageProvider(
    this.asset,
    this.thumbnailSize, {
    this.scope,
    this.cover = false,
  });

  final AssetEntity asset;
  final ThumbnailSize thumbnailSize;

  /// Cancels the request when the page or the row that owns it goes away.
  final MediaLoadScope? scope;

  /// Cover/grid requests are queued ahead of speculative ones.
  final bool cover;

  @override
  Future<LocalThumbImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    LocalThumbImageProvider key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(
    _load(key, decode),
    informationCollector: () => [
      DiagnosticsProperty<LocalThumbImageProvider>('provider', this),
      DiagnosticsProperty<String>('asset', key.asset.id),
    ],
  );

  Future<ImageInfo> _load(
    LocalThumbImageProvider key,
    ImageDecoderCallback decode,
  ) async {
    final bytes = await LocalMedia.thumbnail(
      key.asset,
      key.thumbnailSize,
      scope: key.scope,
      cover: key.cover,
    );
    if (bytes == null || bytes.isEmpty) {
      throw StateError('LOCAL_THUMBNAIL_EMPTY');
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final codec = await decode(buffer);
    try {
      final frame = await codec.getNextFrame();
      return ImageInfo(image: frame.image);
    } finally {
      codec.dispose();
    }
  }

  @override
  bool operator ==(Object other) =>
      other is LocalThumbImageProvider &&
      other.asset.id == asset.id &&
      other.thumbnailSize == thumbnailSize;

  @override
  int get hashCode => Object.hash(asset.id, thumbnailSize);
}

@immutable
class LocalOriginalImageProvider extends ImageProvider<LocalOriginalImageProvider> {
  const LocalOriginalImageProvider(this.asset, {this.scope, this.knownBytes});

  final AssetEntity asset;
  final MediaLoadScope? scope;

  /// MediaStore size, used to size the deadline (null asks the MediaStore).
  final int? knownBytes;

  @override
  Future<LocalOriginalImageProvider> obtainKey(
    ImageConfiguration configuration,
  ) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    LocalOriginalImageProvider key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(
    _load(key, decode),
    informationCollector: () => [
      DiagnosticsProperty<LocalOriginalImageProvider>('provider', this),
      DiagnosticsProperty<String>('asset', key.asset.id),
    ],
  );

  Future<ImageInfo> _load(
    LocalOriginalImageProvider key,
    ImageDecoderCallback decode,
  ) async {
    final bytes = await LocalMedia.originalBytes(
      key.asset,
      scope: key.scope,
      knownBytes: key.knownBytes,
    );
    if (bytes == null || bytes.isEmpty) {
      throw StateError('LOCAL_ORIGINAL_EMPTY');
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final codec = await decode(buffer);
    try {
      final frame = await codec.getNextFrame();
      return ImageInfo(image: frame.image);
    } finally {
      codec.dispose();
    }
  }

  @override
  bool operator ==(Object other) =>
      other is LocalOriginalImageProvider && other.asset.id == asset.id;

  @override
  int get hashCode => asset.id.hashCode;
}