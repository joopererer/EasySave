// Shared widgets: platform tag, error card with actions.

import 'dart:async';
import 'dart:ui' as ui show ImmutableBuffer, Codec;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../../core/error_copy.dart';
import '../core/dev_log.dart';
import '../../core/models.dart';
import '../../theme/app_theme.dart';
import '../services/auth.dart';
import '../services/site_registry.dart';
import '../services/media_request_policy.dart';
import '../services/authorized_media_http.dart';
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
  });

  final MediaItem item;
  final String platform;
  final BoxFit fit;
  final int? cacheWidth;
  final double? width;
  final double? height;
  final Widget? placeholder;

  @override
  State<CoverImage> createState() => _CoverImageState();
}

class _CoverImageState extends State<CoverImage> {
  @override
  Widget build(BuildContext context) {
    return Image(
      image: CdnImage(
        widget.item,
        platform: widget.platform,
        cacheWidth: widget.cacheWidth,
      ),
      fit: widget.fit,
      width: widget.width,
      height: widget.height,
      gaplessPlayback: true,
      errorBuilder: (context, error, _) => ColoredBox(
        color: Colors.black12,
        child: Center(
          child: Text(
            error is MediaPolicyException ? '该资源地址不在允许范围内' : '图片加载失败',
          ),
        ),
      ),
      loadingBuilder: (context, child, progress) => progress == null
          ? child
          : (widget.placeholder ?? const ColoredBox(color: Colors.black12)),
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

/// Network image provider with per-URL timeout and declared headers. Mirrors the
/// stock NetworkImage memory profile (full bytes only live during the
/// fetch; the codec decodes at [cacheWidth]).
@immutable
class CdnImage extends ImageProvider<CdnImage> {
  const CdnImage(this.item, {required this.platform, this.cacheWidth});

  final MediaItem item;
  final String platform;
  final int? cacheWidth;

  static final _client = http.Client();
  static const _timeout = Duration(seconds: 8);

  static final Map<String, Uint8List> _rawByteCache = {};
  static final List<String> _cacheKeysOrder = [];
  static const int _maxCachedImages = 100;

  static void cacheBytes(String url, Uint8List bytes) {
    if (_rawByteCache.containsKey(url)) {
      _cacheKeysOrder.remove(url);
      _cacheKeysOrder.add(url);
      _rawByteCache[url] = bytes;
      return;
    }
    if (_cacheKeysOrder.length >= _maxCachedImages) {
      final oldest = _cacheKeysOrder.removeAt(0);
      _rawByteCache.remove(oldest);
    }
    _rawByteCache[url] = bytes;
    _cacheKeysOrder.add(url);
  }

  static Uint8List? getCachedBytes(List<String> urls) {
    for (final u in urls) {
      final b = _rawByteCache[u];
      if (b != null) return b;
    }
    return null;
  }

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
    final name = host ??
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
        extra: 'type=${item.type} poster=${item.posterUrl == null ? 'none' : 'set'}',
      );
    }
    final cached = getCachedBytes(ordered.map((r) => r.url).toList());
    if (cached != null) return (bytes: cached, url: ordered.first.url);

    for (final resource in ordered) {
      try {
        final response = await sendAuthorizedMediaGet(
          _client,
          policy,
          resource,
          timeout: _timeout,
        );
        final bytes = await response.stream.toBytes().timeout(_timeout);
        if (response.statusCode == 200 && bytes.isNotEmpty) {
          _logPoster(
            'FETCH_OK',
            resource.url,
            extra:
                'headers=${resource.request.headers.keys.map((k) => k.toLowerCase()).join(',')}',
          );
          cacheBytes(resource.url, bytes);
          return (bytes: bytes, url: resource.url);
        }
        _logPoster(
          'HTTP_STATUS',
          resource.url,
          extra: 'status=${response.statusCode} bytes=${bytes.length}',
        );
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
    final fetched = await _fetchBytes();
    final buffer = await ui.ImmutableBuffer.fromUint8List(fetched.bytes);
    try {
      // Bypass the injected decoder on purpose: the stock callback in this
      // Flutter revision has no resize hook, and decoding multi-MB originals
      // at full size is what froze large posts.
      // ignore: deprecated_member_use
      return await PaintingBinding.instance.instantiateImageCodecFromBuffer(
        buffer,
        cacheWidth: cacheWidth,
      );
    } catch (error) {
      // Non-image bytes (an mp4 poster fallback) fail here, not at the request.
      _logPoster(
        'DECODE_FAILED',
        fetched.url,
        extra: 'error=${error.runtimeType} bytes=${fetched.bytes.length}',
      );
      rethrow;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is CdnImage &&
      identical(other.item, item) &&
      other.platform == platform &&
      other.cacheWidth == cacheWidth;

  @override
  int get hashCode => Object.hash(identityHashCode(item), platform, cacheWidth);
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
  static const _assets = <String, IconData>{
    'xhs': Icons.menu_book,
    'instagram': Icons.photo_camera,
    'x': Icons.alternate_email,
    'tiktok': Icons.music_note,
  };
  @override
  Widget build(BuildContext context) => Icon(
    _assets[SiteRegistry.current.byId(platform)?.assetKey] ?? Icons.public,
    size: size,
    color: color,
  );
}

class PlatformTag extends StatelessWidget {
  const PlatformTag({super.key, required this.platform, this.savedDisplayName});
  final String platform;
  final String? savedDisplayName;

  @override
  Widget build(BuildContext context) {
    final raw = SiteRegistry.current.byId(platform)?.data['tagColor'];
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
