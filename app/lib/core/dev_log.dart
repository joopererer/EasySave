// Device log that is easy to collect during manual verification.
//
// Every line goes to logcat (tag "flutter" on Android, so `adb logcat -s
// V16DL` does NOT work — filter with `adb logcat | grep V16DL`) and is
// appended to <external files dir>/v16dl.log, which can be pulled with
// `adb pull /sdcard/Android/data/com.james.easysave/files/v16dl.log`.

import 'dart:io';

import 'package:path_provider/path_provider.dart';

abstract final class DevLog {
  /// File name inside the app's external files directory.
  static const String fileName = 'v16dl.log';

  static Future<void> write(String tag, String message) async {
    final line = '[$tag] $message';
    // ignore: avoid_print
    print(line);
    try {
      final dir = await getExternalStorageDirectory();
      if (dir == null) return;
      final file = File('${dir.path}/$fileName');
      await file.writeAsString(
        '$line\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // Logging must never break the caller.
    }
  }
}
