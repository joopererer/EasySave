import 'package:flutter/widgets.dart';

/// Keeps a few decoded images alive for one gallery session.
///
/// Each kept provider holds a listener on its image stream, so the image cache
/// keeps it as a live image even when a large original does not fit the
/// cache's byte budget and its page has been disposed. Swiping back to a kept
/// page shows it at once instead of decoding again; keeping the neighbours
/// decodes them ahead of time. At most [capacity] images are held; the least
/// recently kept one is released first.
class DecodedImageKeeper {
  DecodedImageKeeper({this.capacity = 5});

  final int capacity;
  final _entries = <ImageProvider, (ImageStream, ImageStreamListener)>{};

  int get length => _entries.length;
  bool holds(ImageProvider provider) => _entries.containsKey(provider);

  void keep(ImageProvider provider, ImageConfiguration configuration) {
    final existing = _entries.remove(provider);
    if (existing != null) {
      _entries[provider] = existing;
      return;
    }
    final stream = provider.resolve(configuration);
    final listener = ImageStreamListener(
      (_, _) {},
      // A file that cannot be decoded is reported by the visible page.
      onError: (_, _) {},
    );
    stream.addListener(listener);
    _entries[provider] = (stream, listener);
    while (_entries.length > capacity) {
      _release(_entries.keys.first);
    }
  }

  void _release(ImageProvider provider) {
    final entry = _entries.remove(provider);
    entry?.$1.removeListener(entry.$2);
  }

  void dispose() {
    for (final provider in _entries.keys.toList()) {
      _release(provider);
    }
  }
}
