// Shared widgets: platform tag, error card with actions.

import 'dart:async';
import 'dart:ui' as ui show ImmutableBuffer, Codec;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../../core/error_copy.dart';
import '../../core/models.dart';
import '../../theme/app_theme.dart';

/// Primary capsule button: red-orange gradient with white text.
class GradientButton extends StatelessWidget {
  const GradientButton({
    super.key,
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: AppTokens.mainGradient,
          borderRadius: BorderRadius.all(Radius.circular(999)),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onPressed,
            borderRadius: const BorderRadius.all(Radius.circular(999)),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 14),
              alignment: Alignment.center,
              child: Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Image with CDN fallback rotation, platform Referer and per-URL timeout.
///
/// XHS image hosts intermittently blackhole a request (no data, no error)
/// or require a Referer, and Image.network has no timeout — a bare one
/// hangs the cell forever. This provider walks the URL list with `http`
/// (8s per URL) and decodes at [cacheWidth], so every cell resolves to
/// pixels or a broken icon in bounded time. Bytes are transient (freed
/// after decode like a stock NetworkImage); nothing full-size is pinned.
class CoverImage extends StatefulWidget {
  const CoverImage({
    super.key,
    required this.item,
    required this.referer,
    this.fit = BoxFit.cover,
    this.cacheWidth,
    this.width,
    this.height,
  });

  final MediaItem item;
  final String referer;
  final BoxFit fit;
  final int? cacheWidth;
  final double? width;
  final double? height;

  @override
  State<CoverImage> createState() => _CoverImageState();
}

class _CoverImageState extends State<CoverImage> {
  @override
  Widget build(BuildContext context) {
    return Image(
      image: CdnImage(
        urlsFor(widget.item),
        referer: widget.referer,
        cacheWidth: widget.cacheWidth,
      ),
      fit: widget.fit,
      width: widget.width,
      height: widget.height,
      gaplessPlayback: true,
      errorBuilder: (context, _, _) => const ColoredBox(
        color: Colors.black12,
        child: Icon(Icons.broken_image),
      ),
      loadingBuilder: (context, child, progress) =>
          progress == null ? child : const ColoredBox(color: Colors.black12),
    );
  }
}

/// Display URLs for an item: video items resolve to their still-image
/// cover (the item url itself may be an mp4), CDN originals first with
/// the rewritten primary kept last as a fallback.
List<String> urlsFor(MediaItem item) {
  final cover = item.type == 'video' ? item.posterUrl : null;
  return [...item.fallbacks, if (cover != null) cover, item.url];
}

/// Network image provider with per-URL timeout and Referer. Mirrors the
/// stock NetworkImage memory profile (full bytes only live during the
/// fetch; the codec decodes at [cacheWidth]).
@immutable
class CdnImage extends ImageProvider<CdnImage> {
  const CdnImage(this.urls, {required this.referer, this.cacheWidth});

  final List<String> urls;
  final String referer;
  final int? cacheWidth;

  static final _client = http.Client();
  static const _timeout = Duration(seconds: 8);

  Future<Uint8List> _fetchBytes() async {
    for (final url in urls) {
      try {
        final response = await _client
            .get(Uri.parse(url), headers: {'Referer': referer})
            .timeout(_timeout);
        if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
          return response.bodyBytes;
        }
      } catch (_) {
        // Timeout, DNS, TLS, 403 — try the next URL.
      }
    }
    throw StateError('all image urls failed: ${urls.firstOrNull}');
  }

  @override
  Future<CdnImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<CdnImage>(this);

  @override
  ImageStreamCompleter loadImage(CdnImage key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, decode),
      scale: 1.0,
      debugLabel: urls.firstOrNull,
    );
  }

  Future<ui.Codec> _loadAsync(CdnImage key, ImageDecoderCallback decode) async {
    assert(key == this);
    final bytes = await _fetchBytes();
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    // Bypass the injected decoder on purpose: the stock callback in this
    // Flutter revision has no resize hook, and decoding multi-MB originals
    // at full size is what froze large posts.
    // ignore: deprecated_member_use
    return PaintingBinding.instance.instantiateImageCodecFromBuffer(
      buffer,
      cacheWidth: cacheWidth,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CdnImage &&
      listEquals(other.urls, urls) &&
      other.referer == referer &&
      other.cacheWidth == cacheWidth;

  @override
  int get hashCode => Object.hash(Object.hashAll(urls), referer, cacheWidth);
}

class PlatformTag extends StatelessWidget {
  const PlatformTag({super.key, required this.platform});

  final String platform;

  @override
  Widget build(BuildContext context) {
    final isXhs = platform == 'xhs';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: isXhs ? AppTokens.platformXhs : AppTokens.platformIg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        isXhs ? '小红书' : 'Instagram',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Error card driven by the centralized error copy: message, action button,
/// and a diagnostics button on INVALID_PAGE failures.
class ErrorCard extends StatelessWidget {
  const ErrorCard({
    super.key,
    required this.code,
    required this.onAction,
    this.diagnostics,
  });

  final String code;
  final Future<void> Function(ErrorAction action) onAction;
  final String Function()? diagnostics;

  @override
  Widget build(BuildContext context) {
    final copy = errorCopyFor(code);
    return Card(
      color: SecondaryBg.pink(context),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(copy.message, style: const TextStyle(fontSize: 14)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                FilledButton(
                  onPressed: () => onAction(copy.action),
                  child: Text(_actionLabel(copy.action)),
                ),
                if (code == ParseErrorCode.invalidPage && diagnostics != null)
                  OutlinedButton(
                    onPressed: () async {
                      await Clipboard.setData(
                        ClipboardData(text: diagnostics!()),
                      );
                    },
                    child: const Text('复制诊断信息'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _actionLabel(ErrorAction action) {
    switch (action) {
      case ErrorAction.goLogin:
        return '去登录';
      case ErrorAction.backHome:
        return '返回首页';
      case ErrorAction.retry:
        return '重试';
      case ErrorAction.repaste:
        return '重新粘贴';
    }
  }
}
