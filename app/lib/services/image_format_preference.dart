// The 图片格式 download setting (v1.11 batch 3).
//
// It changes *which bytes* a still is saved as, never how they are fetched:
//
//   * [compat]   — 「兼容优先」(the default): the v1.10.3 rules — a full-quality
//                  jpeg transcode first, then an original this device can
//                  decode, then the preview-size copy marked 「非原图」.
//   * [original] — 「原始格式」: the original bytes win, HEIC / WebP / AVIF
//                  included. When this device cannot display the container the
//                  file is still saved, and the completion note says so.
//   * [jpeg]     — 「JPEG」: only a jpeg result is accepted. When no jpeg
//                  candidate exists the compat rules are used and the note
//                  says 「未取得 JPEG，已按兼容优先保存」.
//
// It only applies to 小红书 stills: every other platform's parser hands out one
// kind of still URL, so there is nothing to choose between.

enum ImageFormatPreference {
  compat('兼容优先'),
  original('原始格式'),
  jpeg('JPEG');

  const ImageFormatPreference(this.label);

  /// The Chinese label shown in 我的 → 设置 → 下载.
  final String label;

  /// What the setting does, in one sentence, for the settings page.
  String get description => switch (this) {
    ImageFormatPreference.compat =>
      '优先保存转码后的 JPEG；拿不到时用本机可解码的原图，最后才用预览图（标「非原图」）。',
    ImageFormatPreference.original =>
      '优先保存原图字节（含 HEIC / WebP / AVIF）。本机无法解码时照常保存，并提示可能无法显示。',
    ImageFormatPreference.jpeg =>
      '只接受 JPEG 结果；拿不到时按「兼容优先」保存并提示。',
  };

  /// The token used in the download log (never localized).
  String get logToken => name;

  static ImageFormatPreference fromName(String? name) {
    for (final value in ImageFormatPreference.values) {
      if (value.name == name) return value;
    }
    return ImageFormatPreference.compat;
  }
}

/// Containers a phone may hold but not necessarily display. Used to decide
/// whether saving the original bytes deserves the completion note — a plain
/// check of the file name, never a decode.
const Set<String> kOriginalOnlyStillExtensions = {
  'heic',
  'heif',
  'avif',
  'webp',
};

/// The extension of [filename], lower case, without the dot.
String stillExtensionOf(String? filename) {
  final name = (filename ?? '').trim().toLowerCase();
  final dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot + 1);
}
