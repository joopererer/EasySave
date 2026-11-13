// Read-only, on-device self-check for still containers.
//
// `flutter build apk --release --dart-define=EASYSAVE_HEIC_SELFCHECK=true`
// turns this on. At start-up it lists the files the user copied into
// `<app external files>/heic-probe/`, asks the platform decoders of the phone
// to decode each one, and writes one `[HeicSelfCheck]` line per file into the
// same log the app already writes.
//
// Rules this respects:
// * it only ever reads app-private storage (`getExternalStorageDirectory()` is
//   the app's own external files directory), never the shared album, the
//   download folder or another app's data;
// * it never writes, moves or deletes a file;
// * every probe is bounded and runs on the native probe executor, so the app
//   starts normally even when a decode hangs.

import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../core/dev_log.dart';
import 'image_decode_probe.dart';

/// Compile-time switch; an undefined key makes the whole feature dead code.
const bool kHeicSelfCheck = bool.fromEnvironment('EASYSAVE_HEIC_SELFCHECK');

/// Directory (inside the app's own external files) the samples are read from.
const String kHeicSelfCheckDir = 'heic-probe';

/// Extensions the self-check looks at.
const Set<String> kHeicSelfCheckExtensions = {'heic', 'heif', 'avif', 'jpg'};

class HeicSelfCheck {
  HeicSelfCheck._();

  /// Runs the check when the build enabled it. Never throws.
  static Future<void> runIfEnabled() async {
    if (!kHeicSelfCheck) return;
    try {
      await run();
    } catch (error) {
      unawaited(DevLog.write(
        'HeicSelfCheck',
        'event=failed reason=${error.runtimeType}',
      ));
    }
  }

  /// Probes every sample found in [kHeicSelfCheckDir].
  static Future<int> run() async {
    final root = await getExternalStorageDirectory();
    if (root == null) return 0;
    final dir = Directory('${root.path}/$kHeicSelfCheckDir');
    if (!await dir.exists()) {
      unawaited(DevLog.write(
        'HeicSelfCheck',
        'event=skipped reason=no_dir',
      ));
      return 0;
    }
    final files = <File>[
      await for (final entity in dir.list(followLinks: false))
        if (entity is File)
          if (kHeicSelfCheckExtensions
              .contains(entity.path.split('.').last.toLowerCase()))
            entity,
    ]..sort((a, b) => a.path.compareTo(b.path));
    var probed = 0;
    for (final file in files) {
      // The probe refuses anything outside app storage; a symlink that points
      // elsewhere is simply not followed.
      final bytes = await file.length().catchError((_) => -1);
      final result = await ImageDecodeProbe.probeTempFile(file.path);
      probed++;
      unawaited(DevLog.write(
        'HeicSelfCheck',
        'sample name=${file.path.split(Platform.pathSeparator).last} '
            'bytes=$bytes '
            'verdict=${result.verdict.name} '
            'decoder=${result.decoder.isEmpty ? '-' : result.decoder} '
            'reason=${result.reason.isEmpty ? '-' : result.reason} '
            'bounds=${result.width}x${result.height}',
      ));
    }
    return probed;
  }
}
