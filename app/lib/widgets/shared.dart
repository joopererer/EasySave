// Shared widgets: platform tag, error card with actions.

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
/// hangs the cell forever. So bytes are fetched with `http` (8s per URL)
/// and rendered from memory; every cell resolves to pixels or a broken
/// icon in bounded time.
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
  static const _timeout = Duration(seconds: 8);
  static http.Client? _client;

  Uint8List? _bytes;
  bool _failed = false;
  int _generation = 0;

  List<String> get _urls {
    // Video items show their still-image cover; the item url itself may
    // be an mp4 that cannot render as an image.
    final cover = widget.item.type == 'video' ? widget.item.posterUrl : null;
    // Display order: CDN originals first. The rewritten ci.xiaohongshu.com
    // primary is occasionally slow/unreachable from mobile networks (the
    // 0/2/6 pattern); it stays in the rotation as a fallback.
    return [
      ...widget.item.fallbacks,
      if (cover != null) cover,
      widget.item.url,
    ];
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(CoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.url != widget.item.url) _load();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _bytes = null;
      _failed = false;
    });
    _client ??= http.Client();
    for (final url in _urls) {
      try {
        final response = await _client!
            .get(Uri.parse(url), headers: {'Referer': widget.referer})
            .timeout(_timeout);
        if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
          continue;
        }
        if (!mounted || generation != _generation) return;
        setState(() => _bytes = response.bodyBytes);
        return;
      } catch (_) {
        // Timeout, DNS, TLS, 403 — try the next URL.
      }
    }
    if (!mounted || generation != _generation) return;
    setState(() => _failed = true);
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes != null) {
      return Image.memory(
        bytes,
        fit: widget.fit,
        width: widget.width,
        height: widget.height,
        gaplessPlayback: true,
        cacheWidth: widget.cacheWidth,
        errorBuilder: (context, _, _) =>
            const ColoredBox(color: Colors.black12),
      );
    }
    if (_failed) {
      return const ColoredBox(
        color: Colors.black12,
        child: Icon(Icons.broken_image),
      );
    }
    return const ColoredBox(color: Colors.black12);
  }
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
