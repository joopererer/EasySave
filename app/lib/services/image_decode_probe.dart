// Device capability check for still containers the platform may not decode.
//
// A HEIC that carries an alpha auxiliary image is written by iPhones, and
// Android 12's HEIF decoder rejects it: the album shows no thumbnail, the
// history page stalls on it and MediaStore metadata extraction never finishes.
// The bytes are therefore checked against the decoders of *this* phone before
// the file may reach the album.
//
// The probe runs on a native executor of its own (never photo_manager's queue,
// never the main thread) and every call is bounded here as well. A Dart
// timeout cannot cancel the native decode, which is exactly why nothing is
// shared between calls: a decode that never returns costs one ignored answer,
// not a slot other files have to wait for.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/dev_log.dart';
import 'heif_bytes.dart';
import 'media_content_type.dart';

/// What the platform decoders said about one file.
enum ImageDecodeVerdict {
  /// The device decoded a sampled copy: the file is safe to save.
  decodable,

  /// The device could not decode it: it must not be saved.
  undecodable,

  /// No answer (timeout, missing channel, engine without the method): the
  /// caller keeps its previous behaviour instead of rejecting on a guess.
  unknown,
}

class ImageDecodeResult {
  const ImageDecodeResult(
    this.verdict, {
    this.width = 0,
    this.height = 0,
    this.decoder = '',
    this.reason = '',
    this.bytes = 0,
  });

  final ImageDecodeVerdict verdict;
  final int width;
  final int height;
  final String decoder;
  final String reason;
  final int bytes;

  bool get isDecodable => verdict == ImageDecodeVerdict.decodable;
  bool get isUndecodable => verdict == ImageDecodeVerdict.undecodable;
}

/// Answer of the native probe, or null when the platform has none.
typedef DecodeProbeCall = Future<Map<Object?, Object?>?> Function(
  String method,
  Map<String, Object?> arguments,
);

/// Device verdict for one finished still, and whether a probe ran at all.
class StillDecodeGate {
  const StillDecodeGate.notRequired()
    : probed = false,
      result = null;

  const StillDecodeGate.probed(this.result) : probed = true;

  /// Whether the container needed a device check.
  final bool probed;

  /// Null when [probed] is false.
  final ImageDecodeResult? result;

  /// The device cannot decode the file: it must not reach the album.
  bool get rejected => result?.isUndecodable == true;

  /// Fixed log fields (no path, no id).
  String get logFields => !probed
      ? ''
      : 'device_probe=${result!.verdict.name} '
            'device_decoder=${result!.decoder.isEmpty ? '-' : result!.decoder} '
            'device_reason=${result!.reason.isEmpty ? '-' : result!.reason}';

  /// Gate of a finished download: probes [path] only when its own header says
  /// the container depends on the device codecs ([requiresDeviceDecode]).
  ///
  /// A HEIC/HEIF is decided from its own bytes ([readHeifHeaderOfFile]): the
  /// device decoder is never asked, because asking it is what stalled the
  /// history page and cost build 46 every thumbnail behind the stuck decode.
  static Future<StillDecodeGate> forStoredStill(
    MediaContentType? content,
    String path,
  ) async {
    if (content == null || !requiresDeviceDecode(content)) {
      return const StillDecodeGate.notRequired();
    }
    if (isHeifExtension(content.extension)) {
      final header = await readHeifHeaderOfFile(path);
      final sdk = await ImageDecodeProbe.apiLevel();
      unawaited(DevLog.write('HeifBytes', 'source=temp ${header.logFields}'));
      if (header.verdict == HeifVerdict.unknown) {
        return const StillDecodeGate.probed(
          ImageDecodeResult(ImageDecodeVerdict.unknown, reason: 'heif_unread'),
        );
      }
      if (heifAlphaUndisplayable(header, sdk)) {
        return StillDecodeGate.probed(
          ImageDecodeResult(
            ImageDecodeVerdict.undecodable,
            decoder: heifByteDecoder,
            reason: heifAlphaReason,
            bytes: header.bytes,
          ),
        );
      }
      return StillDecodeGate.probed(
        ImageDecodeResult(
          ImageDecodeVerdict.decodable,
          decoder: heifByteDecoder,
          bytes: header.bytes,
        ),
      );
    }
    return StillDecodeGate.probed(await ImageDecodeProbe.probeTempFile(path));
  }
}

/// The decision came from the container bytes, not from a decoder.
const String heifByteDecoder = 'heif_bytes';

/// Fixed reason token of a still this device cannot show.
const String heifAlphaReason = 'alpha_aux';

/// Why an album still was rejected, from its own bytes.
const String heifAlphaUnknownReason = 'heif_unread';

class ImageDecodeProbe {
  ImageDecodeProbe._();

  static const MethodChannel channel = MethodChannel('easysave/media');

  /// Replaces the gate in tests (production: [StillDecodeGate.forStoredStill]).
  static Future<StillDecodeGate> Function(MediaContentType?, String)?
  stillGateForTesting;

  /// How long a probe may take before the caller moves on. The native decode
  /// keeps running on its own thread; its answer is simply not waited for.
  static Duration timeout = const Duration(seconds: 4);

  /// The device's Android API level, asked once and cached. Null when the
  /// platform has no answer (tests, desktop): an unknown level never rejects a
  /// file, it keeps the previous behaviour.
  static int? _apiLevel;

  @visibleForTesting
  static void setApiLevelForTesting(int? value) => _apiLevel = value;

  static Future<int?> apiLevel() async {
    if (_apiLevel != null) return _apiLevel;
    try {
      _apiLevel = await channel.invokeMethod<int>('apiLevel');
    } catch (_) {
      // No channel (tests / other platforms) leaves the level unknown.
    }
    return _apiLevel;
  }

  /// Test seam: replaces the platform call only, never the decision logic.
  static DecodeProbeCall? callForTesting;

  static Future<DecodeProbeCall> _caller() async => callForTesting ?? _invoke;

  static Future<Map<Object?, Object?>?> _invoke(
    String method,
    Map<String, Object?> arguments,
  ) => channel.invokeMapMethod<Object?, Object?>(method, arguments);

  /// A bounded prefix of an album file's bytes, for header-only decisions.
  /// Returns an empty list when the platform cannot read it.
  static Future<Uint8List> readMediaBytes(
    String mediaId, {
    int maxBytes = kHeifHeadBytes,
  }) async {
    try {
      final raw = await channel.invokeMethod<Uint8List>('readMediaBytes', {
        'id': mediaId,
        'maxBytes': maxBytes,
      });
      return raw ?? Uint8List(0);
    } catch (_) {
      return Uint8List(0);
    }
  }

  /// Probes a downloaded still in EasySave's own temp storage before import.
  static Future<ImageDecodeResult> probeTempFile(String path) =>
      probe('file', {'path': path});

  /// Probes an album still the history already holds, by MediaStore id.
  static Future<ImageDecodeResult> probeMediaId(String mediaId) =>
      probe('media', {'id': mediaId});

  static Future<ImageDecodeResult> probe(
    String kind,
    Map<String, Object?> arguments,
  ) async {
    final watch = Stopwatch()..start();
    final result = await _answered(kind, arguments);
    DevLog.write(
      'DecodeProbe',
      'event=probe kind=$kind verdict=${result.verdict.name} '
          'decoder=${result.decoder.isEmpty ? '-' : result.decoder} '
          'reason=${result.reason.isEmpty ? '-' : result.reason} '
          'bounds=${result.width}x${result.height} bytes=${result.bytes} '
          'ms=${watch.elapsedMilliseconds}',
    );
    return result;
  }

  static Future<ImageDecodeResult> _answered(
    String kind,
    Map<String, Object?> arguments,
  ) async {
    try {
      final reply = await (await _caller())
          .call(kind == 'file' ? 'probeImageDecodable' : 'probeMediaDecodable', arguments)
          .timeout(timeout);
      if (reply == null) return const ImageDecodeResult(ImageDecodeVerdict.unknown);
      final decodable = reply['decodable'];
      return ImageDecodeResult(
        decodable == true
            ? ImageDecodeVerdict.decodable
            : decodable == false
            ? ImageDecodeVerdict.undecodable
            : ImageDecodeVerdict.unknown,
        width: (reply['width'] as num?)?.toInt() ?? 0,
        height: (reply['height'] as num?)?.toInt() ?? 0,
        decoder: '${reply['decoder'] ?? ''}',
        reason: '${reply['reason'] ?? ''}',
        bytes: (reply['bytes'] as num?)?.toInt() ?? 0,
      );
    } on TimeoutException {
      return const ImageDecodeResult(
        ImageDecodeVerdict.unknown,
        reason: 'timeout',
      );
    } on MissingPluginException {
      return const ImageDecodeResult(
        ImageDecodeVerdict.unknown,
        reason: 'no_channel',
      );
    } on PlatformException catch (e) {
      return ImageDecodeResult(ImageDecodeVerdict.unknown, reason: e.code);
    } catch (e) {
      return ImageDecodeResult(
        ImageDecodeVerdict.unknown,
        reason: e.runtimeType.toString(),
      );
    }
  }
}
