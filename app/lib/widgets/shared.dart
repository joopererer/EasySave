// Shared widgets: platform tag, error card with actions.

import 'dart:async';
import 'dart:ui' as ui show ImmutableBuffer, Codec, TargetImageSize, FrameInfo;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter/services.dart';

import '../../core/error_copy.dart';
import '../core/dev_log.dart';
import '../../core/models.dart';
import '../../theme/app_theme.dart';
import '../services/auth.dart';
import '../services/site_registry.dart';
import '../services/media_request_policy.dart';
import '../services/shared_preview_cache.dart';
import '../../core/media_request.dart';

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

/// Image with authorized CDN fallback rotation and per-URL timeout.
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
    required this.platform,
    this.fit = BoxFit.cover,
    this.cacheWidth,
    this.width,
    this.height,
    this.placeholder,
    this.fullResolution = false,
  });

  final MediaItem item;
  final String platform;
  final BoxFit fit;
  final int? cacheWidth;
  final double? width;
  final double? height;
  final Widget? placeholder;
  final bool fullResolution;

  @override
  State<CoverImage> createState() => _CoverImageState();
}

class _CoverImageState extends State<CoverImage> {
  int _retry = 0;
  @override
  Widget build(BuildContext context) {
    if (widget.item.url.isEmpty && (widget.item.posterUrl?.isEmpty ?? true)) {
      return const ColoredBox(
        color: Colors.black12,
        child: Center(child: Icon(Icons.broken_image)),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = widget.fullResolution
            ? null
            : widget.cacheWidth ??
                  ((constraints.maxWidth.isFinite
                              ? constraints.maxWidth
                              : MediaQuery.sizeOf(context).width) *
                          MediaQuery.devicePixelRatioOf(context))
                      .ceil();
        return Image(
          key: ValueKey(_retry),
          image: CdnImage(
            widget.item,
            platform: widget.platform,
            cacheWidth: width,
          ),
          fit: widget.fit,
          width: widget.width,
          height: widget.height,
          gaplessPlayback: true,
          errorBuilder: (context, error, _) => ColoredBox(
            color: Colors.black12,
            child: InkWell(
              onTap: () async {
                await CdnImage(
                  widget.item,
                  platform: widget.platform,
                  cacheWidth: width,
                ).evict();
                if (mounted) setState(() => _retry++);
              },
              child: Center(
                child: Text(
                  error is MediaPolicyException ? '该资源地址不在允许范围内' : '加载失败，点击重试',
                ),
              ),
            ),
          ),
          loadingBuilder: (context, child, progress) => progress == null
              ? child
              : (widget.placeholder ?? const ColoredBox(color: Colors.black12)),
        );
      },
    );
  }
}

/// Display URLs for an item: video items resolve to their still-image
/// cover (the item url itself may be an mp4), CDN originals first with
/// the rewritten primary kept last as a fallback.
List<String> urlsFor(MediaItem item) {
  if (item.type == 'video') {
    if (item.posterUrl != null &&
        item.posterUrl != item.videoUrl &&
        item.posterUrl != item.url) {
      return [item.posterUrl!];
    }
    if (item.videoUrl != null && item.videoUrl != item.url) {
      return [...item.fallbacks, item.url];
    }
    return const [];
  }
  return [...item.fallbacks, item.url];
}

/// Network image provider with per-URL timeout and declared headers. Mirrors the
/// stock NetworkImage memory profile (full bytes only live during the
/// fetch; the codec decodes at [cacheWidth]).
@immutable
class CdnImage extends ImageProvider<CdnImage> {
  const CdnImage(
    this.item, {
    required this.platform,
    this.cacheWidth,
    this.thumbnailCache,
  });

  final MediaItem item;
  final String platform;
  final int? cacheWidth;
  final SharedThumbnailCache? thumbnailCache;

  String get cacheIdentity => thumbnailIdentity(
    platform,
    item.cachePostId ?? 'unbound',
    item.cacheItemIndex ?? identityHashCode(item),
    item.type == 'video' ? 'poster' : 'thumb',
  );

  /// One [PreviewPoster] line per (reason, host) keeps a grid of identical
  /// failing tiles from filling the log.
  static final Set<String> _posterLogged = {};

  static void _logPoster(
    String reason,
    String url, {
    String extra = '',
    String? host,
  }) {
    final uri = Uri.tryParse(url);
    final name =
        host ??
        (uri == null || uri.host.isEmpty ? '-' : uri.host.toLowerCase());
    if (!_posterLogged.add('$reason|$name')) return;
    unawaited(
      DevLog.write(
        'PreviewPoster',
        'reason=$reason host=$name${extra.isEmpty ? '' : ' $extra'}',
      ),
    );
  }

  /// Image/poster resources of [item] after the policy has validated every
  /// declared URL. A rejection is logged before it propagates so a cover that
  /// never loads names its host and reason.
  List<MediaRequestResource> _imageResources(MediaRequestPolicy policy) {
    try {
      return policy
          .resourcesFor(item)
          .where(
            (r) =>
                r.role == MediaResourceRole.image ||
                r.role == MediaResourceRole.poster ||
                (r.role == MediaResourceRole.fallback &&
                    r.fallbackFor != MediaResourceRole.video),
          )
          .toList();
    } on MediaPolicyException catch (error) {
      _logPoster(
        'POLICY',
        '',
        host: error.host.isEmpty ? null : error.host,
        extra: 'code=${error.code}',
      );
      rethrow;
    }
  }

  Future<({Uint8List bytes, String url})> _fetchBytes() async {
    final site = SiteRegistry.current.byId(platform);
    if (site == null) {
      _logPoster('SITE_REJECTED', item.url);
      throw const MediaPolicyException('REQUEST_SITE_REJECTED', '');
    }
    final policy = MediaRequestPolicy(site);
    final resources = _imageResources(policy);
    final ordered = <MediaRequestResource>[];
    for (final url in urlsFor(item)) {
      final resource = resources.where((r) => r.url == url).firstOrNull;
      if (resource != null && !ordered.contains(resource)) {
        ordered.add(resource);
      }
    }
    // A video whose parser result carries no cover has no image resource at
    // all: only its own media URL would be left, which can never decode.
    if (ordered.isEmpty) {
      _logPoster(
        'NO_COVER_DECLARED',
        item.url,
        extra:
            'type=${item.type} poster=${item.posterUrl == null ? 'none' : 'set'}',
      );
    }
    for (final resource in ordered) {
      try {
        final cachedImage =
            await (thumbnailCache ?? SharedThumbnailCache.instance).load(
              policy,
              resource,
              identity: cacheIdentity,
            );
        final bytes = cachedImage.bytes;
        _logPoster(
          'FETCH_OK',
          resource.url,
          extra:
              'headers=${resource.request.headers.keys.map((key) => key.toLowerCase()).join(',')}',
        );
        return (bytes: bytes, url: resource.url);
      } on MediaPolicyException catch (error) {
        _logPoster(
          'POLICY',
          resource.url,
          host: error.host.isEmpty ? null : error.host,
          extra: 'code=${error.code}',
        );
        rethrow;
      } catch (error) {
        // Timeout, DNS, TLS, 403: try the next authorized URL.
        _logPoster(
          'REQUEST_FAILED',
          resource.url,
          extra: 'error=${error.runtimeType}',
        );
      }
    }
    _logPoster('ALL_FAILED', item.url, extra: 'candidates=${ordered.length}');
    throw StateError('all image urls failed');
  }

  @override
  Future<CdnImage> obtainKey(ImageConfiguration configuration) async {
    // ImageCache may reuse a decoded frame without invoking _fetchBytes.
    // Recheck the current signed manifest and expiry even on a cache hit.
    final site = SiteRegistry.current.byId(platform);
    if (site == null) {
      _logPoster('SITE_REJECTED', item.url);
      throw const MediaPolicyException('REQUEST_SITE_REJECTED', '');
    }
    _imageResources(MediaRequestPolicy(site));
    return this;
  }

  @override
  ImageStreamCompleter loadImage(CdnImage key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, decode),
      scale: 1.0,
      debugLabel: platform,
    );
  }

  Future<ui.Codec> _loadAsync(CdnImage key, ImageDecoderCallback decode) async {
    assert(key == this);
    for (var attempt = 0; ; attempt++) {
      final fetched = await _fetchBytes();
      final buffer = await ui.ImmutableBuffer.fromUint8List(fetched.bytes);
      final timer = Stopwatch()..start();
      try {
        final codec = await SharedThumbnailCache.decodeSlots.run(() async {
          final codec = await decode(
            buffer,
            getTargetSize: cacheWidth == null
                ? null
                : (width, height) {
                    final target = cacheWidth!.clamp(1, width);
                    return ui.TargetImageSize(
                      width: target,
                      height: (height * target / width).round().clamp(
                        1,
                        height,
                      ),
                    );
                  },
          );
          try {
            final frame = await codec.getNextFrame();
            return _LimitedCodec(codec, cacheIdentity, frame);
          } catch (_) {
            codec.dispose();
            rethrow;
          }
        });
        return codec;
      } catch (error) {
        // Non-image bytes (an mp4 poster fallback) fail here, not at the request.
        _logPoster(
          'DECODE_FAILED',
          fetched.url,
          extra: 'error=${error.runtimeType} bytes=${fetched.bytes.length}',
        );
        await (thumbnailCache ?? SharedThumbnailCache.instance).invalidate(
          cacheIdentity,
        );
        if (attempt >= 1) rethrow;
      } finally {
        unawaited(
          DevLog.write(
            'ThumbLoad',
            'event=decode ms=${timer.elapsedMilliseconds} key=${safeCacheLabel(cacheIdentity)}',
          ),
        );
      }
    }
  }

  @override
  bool operator ==(Object other) =>
      other is CdnImage &&
      other.cacheIdentity == cacheIdentity &&
      other.cacheWidth == cacheWidth;

  @override
  int get hashCode => Object.hash(cacheIdentity, cacheWidth);
}

/// Codec creation is cheap; getNextFrame is where pixel decoding happens.
/// Keep the slot until that frame completes, including animated image frames.
class _LimitedCodec implements ui.Codec {
  _LimitedCodec(this.codec, this.identity, this._first);
  final ui.Codec codec;
  final String identity;
  ui.FrameInfo? _first;
  @override
  int get frameCount => codec.frameCount;
  @override
  int get repetitionCount => codec.repetitionCount;
  @override
  void dispose() {
    _first?.image.dispose();
    _first = null;
    codec.dispose();
  }

  @override
  Future<ui.FrameInfo> getNextFrame() {
    final first = _first;
    if (first != null) {
      _first = null;
      return Future.value(first);
    }
    return SharedThumbnailCache.decodeSlots.run(() async {
      final timer = Stopwatch()..start();
      try {
        return await codec.getNextFrame();
      } finally {
        unawaited(
          DevLog.write(
            'ThumbLoad',
            'event=decode ms=${timer.elapsedMilliseconds} key=${safeCacheLabel(identity)}',
          ),
        );
      }
    });
  }
}

/// Local icon registry: manifest keys never become remote URLs or file paths.
class PlatformIcon extends StatelessWidget {
  const PlatformIcon({
    super.key,
    required this.platform,
    this.size = 18,
    this.color,
  });
  final String platform;
  final double size;
  final Color? color;
  static const _assets = <String, String>{
    'xhs': 'xiaohongshu',
    'instagram': 'instagram',
    'x': 'x',
    'tiktok': 'tiktok',
  };
  @override
  Widget build(BuildContext context) {
    final slug =
        _assets[SiteRegistry.current
            .byId(SiteRegistry.current.canonicalId(platform))
            ?.assetKey];
    if (slug == null) return Icon(Icons.public, size: size, color: color);
    return SvgPicture.asset(
      'assets/brands/$slug.svg',
      width: size,
      height: size,
      semanticsLabel: platformLabel(platform),
      colorFilter: ColorFilter.mode(
        color ?? IconTheme.of(context).color ?? Colors.black,
        BlendMode.srcIn,
      ),
    );
  }
}

class PlatformTag extends StatelessWidget {
  const PlatformTag({super.key, required this.platform, this.savedDisplayName});
  final String platform;
  final String? savedDisplayName;

  @override
  Widget build(BuildContext context) {
    final raw = SiteRegistry.current
        .byId(SiteRegistry.current.canonicalId(platform))
        ?.data['tagColor'];
    final color = raw is String && RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(raw)
        ? Color(0xFF000000 | int.parse(raw.substring(1), radix: 16))
        : const Color(0xFF607D8B);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          PlatformIcon(platform: platform, size: 12, color: Colors.white),
          const SizedBox(width: 3),
          Text(
            platformLabel(platform, savedDisplayName: savedDisplayName),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
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
    this.message,
    this.diagnostics,
    this.canLogin = true,
  });

  final String code;
  final String? message;
  final Future<void> Function(ErrorAction action) onAction;
  final String Function()? diagnostics;
  final bool canLogin;

  @override
  Widget build(BuildContext context) {
    final copy = errorCopyFor(code);
    final displayMessage = displayErrorMessage(code, message);
    return Card(
      color: SecondaryBg.pink(context),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(displayMessage, style: const TextStyle(fontSize: 14)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                if (copy.action != ErrorAction.goLogin || canLogin)
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

/// Animated loading shimmer placeholder for thumbnails and cards.
class ShimmerBox extends StatefulWidget {
  const ShimmerBox({
    super.key,
    this.width,
    this.height,
    this.borderRadius = const BorderRadius.all(Radius.circular(8)),
  });

  final double? width;
  final double? height;
  final BorderRadiusGeometry borderRadius;

  @override
  State<ShimmerBox> createState() => _ShimmerBoxState();
}

class _ShimmerBoxState extends State<ShimmerBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            borderRadius: widget.borderRadius,
            gradient: LinearGradient(
              begin: Alignment(-1.5 + 3.0 * _controller.value, -0.3),
              end: Alignment(-0.5 + 3.0 * _controller.value, 0.3),
              colors: const [
                Color(0xFFEBE4DC),
                Color(0xFFF7F3ED),
                Color(0xFFEBE4DC),
              ],
            ),
          ),
        );
      },
    );
  }
}
