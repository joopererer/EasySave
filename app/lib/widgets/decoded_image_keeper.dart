import 'package:flutter/widgets.dart';

/// Keeps a few decoded images alive for one gallery session.
///
/// Each kept provider holds a listener on its image stream, so the image cache
/// keeps it as a live image even when a large original does not fit the
/// cache's byte budget and its page has been disposed. Swiping back to a kept
/// page shows it at once instead of decoding again; keeping the neighbours
/// decodes them ahead of time.
///
/// Two limits apply: at most [capacity] images, and at most [maxDecodedBytes]
/// of decoded pixels (width x height x 4 of what was actually decoded, not the
/// file size). The least recently kept entry is released first, so a session
/// that keeps decoding screen-size images cannot grow without bound.
class DecodedImageKeeper {
  DecodedImageKeeper({
    this.capacity = 5,
    this.maxDecodedBytes = 64 * 1024 * 1024,
  });

  final int capacity;
  final int maxDecodedBytes;

  final _entries = <ImageProvider, _KeeperEntry>{};

  int get length => _entries.length;

  bool holds(ImageProvider provider) => _entries.containsKey(provider);

  /// Decoded bytes currently held (0 while a kept image is still decoding).
  int get decodedBytes =>
      _entries.values.fold<int>(0, (sum, entry) => sum + entry.bytes);

  void keep(ImageProvider provider, ImageConfiguration configuration) {
    final existing = _entries.remove(provider);
    if (existing != null) {
      _entries[provider] = existing;
      return;
    }
    final stream = provider.resolve(configuration);
    final entry = _KeeperEntry();
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        final bytes = info.image.width * info.image.height * 4;
        if (entry.bytes == bytes) return;
        entry.bytes = bytes;
        _enforce();
      },
      // A file that cannot be decoded is reported by the visible page.
      onError: (_, _) {},
    );
    entry.listener = listener;
    stream.addListener(listener);
    entry.stream = stream;
    _entries[provider] = entry;
    _enforce();
  }

  void _enforce() {
    while (_entries.length > capacity) {
      _release(_entries.keys.first);
    }
    while (decodedBytes > maxDecodedBytes && _entries.length > 1) {
      _release(_entries.keys.first);
    }
  }

  void _release(ImageProvider provider) {
    final entry = _entries.remove(provider);
    final stream = entry?.stream;
    final listener = entry?.listener;
    if (stream != null && listener != null) stream.removeListener(listener);
  }

  void dispose() {
    for (final provider in _entries.keys.toList()) {
      _release(provider);
    }
  }
}

class _KeeperEntry {
  ImageStream? stream;
  ImageStreamListener? listener;
  int bytes = 0;
}
