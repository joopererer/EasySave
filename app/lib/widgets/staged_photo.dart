// A still that shows something immediately and sharpens in place (v1.11 batch 3).
//
// The viewer used to draw a local still as one `Image(isOriginal: true)`: an
// empty box while the full-resolution file decoded, then the picture popping in
// at its natural size. A remote still had a thumbnail underneath, but the two
// layers were sized independently, so the sharp frame could arrive in a
// different box than the soft one and the picture jumped.
//
// [StagedPhoto] gives both layers the *same* box — the final frame's aspect
// ratio, i.e. the display frame of the sharp image — so:
//
//   * the placeholder fills the frame from the first frame (stretched to the
//     final aspect ratio, never shown smaller and then enlarged);
//   * the full-resolution image fades in on top over [kStagedPhotoCrossfade],
//     inside the same frame, so nothing moves;
//   * only thumbnails are used as placeholders, never the original bytes;
//   * when the full image fails, the placeholder stays visible and the retry
//     affordance of the full layer is shown with it.
//
// A GIF does not use this: it is an animation from the first frame, so there is
// nothing to fade into.

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Cross-fade from the placeholder to the full-resolution frame.
const Duration kStagedPhotoCrossfade = Duration(milliseconds: 180);

/// The signals a full-resolution layer must report.
class StagedPhotoSignals {
  const StagedPhotoSignals({required this.onFrame, required this.onFailure});

  /// The first frame of the full-resolution image painted.
  final VoidCallback onFrame;

  /// The full-resolution image will not arrive (error, timeout, file gone),
  /// so whatever the layer draws instead — a retry hint — is shown at once.
  final VoidCallback onFailure;
}

class StagedPhoto extends StatefulWidget {
  const StagedPhoto({
    super.key,
    required this.aspectRatio,
    required this.placeholder,
    required this.buildFull,
  });

  /// Width / height of the final image, or null when the source did not say.
  /// When known, both layers are laid out in exactly this frame.
  final double? aspectRatio;

  /// The low-resolution layer: a thumbnail that is usually already decoded.
  final Widget placeholder;

  /// Builds the full-resolution layer. It must report through [signals].
  final Widget Function(StagedPhotoSignals signals) buildFull;

  @override
  State<StagedPhoto> createState() => _StagedPhotoState();
}

class _StagedPhotoState extends State<StagedPhoto> {
  bool _fullVisible = false;

  void _revealFull() {
    if (_fullVisible || !mounted) return;
    // A frame can arrive while this very subtree is being built (a decoded
    // image resolves synchronously inside `Image`); setState during build is
    // not allowed, so that case waits for the end of the frame.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _revealFull();
      });
      return;
    }
    setState(() => _fullVisible = true);
  }

  @override
  Widget build(BuildContext context) {
    final full = widget.buildFull(
      StagedPhotoSignals(onFrame: _revealFull, onFailure: _revealFull),
    );
    final layers = Stack(
      fit: StackFit.passthrough,
      alignment: Alignment.center,
      children: [
        widget.placeholder,
        AnimatedOpacity(
          opacity: _fullVisible ? 1 : 0,
          duration: kStagedPhotoCrossfade,
          curve: Curves.easeOut,
          child: full,
        ),
      ],
    );
    final aspect = widget.aspectRatio;
    if (aspect == null || !aspect.isFinite || aspect <= 0) return layers;
    return AspectRatio(aspectRatio: aspect, child: layers);
  }
}

/// The aspect ratio to hand [StagedPhoto] for an item, or null when unknown.
double? stagedAspectRatio(num? width, num? height) {
  if (width == null || height == null || width <= 0 || height <= 0) return null;
  return width / height;
}
