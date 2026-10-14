// Fullscreen playback for video and Live motion clips.
// One controller per page, disposed on leave; paused when backgrounded.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../core/models.dart';
import '../services/saver.dart';
import '../widgets/shared.dart';

/// Fullscreen video with a control bar. Pauses on backgrounding and
/// releases the controller when the page is left.
class VideoPlayerPage extends StatefulWidget {
  const VideoPlayerPage({
    super.key,
    required this.item,
    required this.platform,
  });

  final MediaItem item;
  final String platform;

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage>
    with WidgetsBindingObserver {
  VideoPlayerController? _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final url = widget.item.videoUrl ?? widget.item.url;
    _controller =
        VideoPlayerController.networkUrl(
            Uri.parse(url),
            httpHeaders: {'Referer': refererFor(widget.platform)},
          )
          ..initialize()
              .then((_) {
                if (!mounted) return;
                setState(() {});
                _controller?.play();
              })
              .catchError((Object e) {
                if (mounted) setState(() => _error = '$e');
              });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _controller?.pause();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    _controller = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
      ),
      body: Center(
        child: _error != null
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  '播放失败：$_error',
                  style: const TextStyle(color: Colors.white),
                ),
              )
            : controller != null && controller.value.isInitialized
            ? _Controls(controller: controller)
            : const CircularProgressIndicator(),
      ),
    );
  }
}

class _Controls extends StatefulWidget {
  const _Controls({required this.controller});

  final VideoPlayerController controller;

  @override
  State<_Controls> createState() => _ControlsState();
}

class _ControlsState extends State<_Controls> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTick);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTick);
    super.dispose();
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  String _stamp(Duration d) {
    final mm = d.inMinutes.remainder(60).toString();
    final ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    final value = widget.controller.value;
    final position = value.position;
    final duration = value.duration;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AspectRatio(
          aspectRatio: value.aspectRatio == 0 ? 16 / 9 : value.aspectRatio,
          child: VideoPlayer(widget.controller),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              IconButton(
                color: Colors.white,
                icon: Icon(value.isPlaying ? Icons.pause : Icons.play_arrow),
                onPressed: () => value.isPlaying
                    ? widget.controller.pause()
                    : widget.controller.play(),
              ),
              Text(
                _stamp(position),
                style: const TextStyle(color: Colors.white),
              ),
              Expanded(
                child: Slider(
                  value: duration.inMilliseconds == 0
                      ? 0
                      : position.inMilliseconds / duration.inMilliseconds,
                  onChanged: (v) => widget.controller.seekTo(
                    Duration(
                      milliseconds: (v * duration.inMilliseconds).round(),
                    ),
                  ),
                ),
              ),
              Text(
                _stamp(duration),
                style: const TextStyle(color: Colors.white),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Fullscreen Live view: static cover by default, long-press plays the
/// motion clip muted and looped, release stops and shows the cover again.
class LivePlayerPage extends StatefulWidget {
  const LivePlayerPage({super.key, required this.item, required this.platform});

  final MediaItem item;
  final String platform;

  @override
  State<LivePlayerPage> createState() => _LivePlayerPageState();
}

class _LivePlayerPageState extends State<LivePlayerPage>
    with WidgetsBindingObserver {
  VideoPlayerController? _controller;
  bool _playing = false;
  bool _starting = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _stop();
  }

  Future<void> _start() async {
    final videoUrl = widget.item.videoUrl;
    if (videoUrl == null || _playing || _starting) return;
    setState(() => _starting = true);
    try {
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(videoUrl),
        httpHeaders: {'Referer': refererFor(widget.platform)},
      );
      await controller.initialize();
      await controller.setVolume(0);
      await controller.setLooping(true);
      if (!mounted) {
        await controller.dispose();
        return;
      }
      _controller = controller;
      setState(() {
        _playing = true;
        _starting = false;
      });
      await controller.play();
    } catch (_) {
      if (mounted) {
        setState(() {
          _failed = true;
          _starting = false;
        });
      }
    }
  }

  Future<void> _stop() async {
    final controller = _controller;
    _controller = null;
    if (mounted) setState(() => _playing = false);
    if (controller != null) {
      try {
        await controller.pause();
      } catch (_) {
        // Best effort; the controller is going away anyway.
      }
      await controller.dispose();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final controller = _controller;
    _controller = null;
    if (controller != null) unawaited(controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final ready =
        _playing && controller != null && controller.value.isInitialized;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
      ),
      body: Center(
        child: GestureDetector(
          onLongPressStart: (_) => _start(),
          onLongPressEnd: (_) => _stop(),
          child: ready
              ? AspectRatio(
                  aspectRatio: controller.value.aspectRatio == 0
                      ? 16 / 9
                      : controller.value.aspectRatio,
                  child: VideoPlayer(controller),
                )
              : Stack(
                  alignment: Alignment.center,
                  children: [
                    CoverImage(
                      item: widget.item,
                      referer: refererFor(widget.platform),
                      fit: BoxFit.contain,
                      cacheWidth: 1080,
                    ),
                    if (_starting)
                      const CircularProgressIndicator(color: Colors.white)
                    else
                      Positioned(
                        bottom: 24,
                        child: Text(
                          _failed ? '播放失败，请重试' : '长按播放实况',
                          style: const TextStyle(color: Colors.white70),
                        ),
                      ),
                  ],
                ),
        ),
      ),
    );
  }
}
