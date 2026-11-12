import 'history_db.dart';

/// Album names are `<sourceId>_<itemIndex>.<extension>` (see
/// [cleanMediaFilename]); the trailing number is the pairing anchor of a Live
/// photo because the still and its motion clip differ only in the extension.
final RegExp _albumSequence = RegExp(r'_(\d+)\.');

/// The 1-based item number encoded in an album file name, or null when the
/// name does not follow the album naming rule.
int? albumSequenceOf(String filename) {
  final match = _albumSequence.firstMatch(filename.trim());
  final digits = match?.group(1);
  if (digits == null) return null;
  final sequence = int.tryParse(digits);
  return (sequence == null || sequence < 1) ? null : sequence;
}

/// One entry of a saved post: a still, a video, or the still **and** motion
/// clip of one Live photo. A Live pair is one entry, never two.
class SavedMediaEntry {
  SavedMediaEntry({required this.itemIndex, this.image, this.video});

  /// 1-based position in the original post (0 when the rows predate the rule).
  final int itemIndex;
  final HistoryFile? image;
  final HistoryFile? video;

  bool get isLive => image != null && video != null;

  /// The row a card or viewer shows first: the still of a Live pair, else
  /// whichever row the entry has.
  HistoryFile get cover => image ?? video!;

  List<HistoryFile> get files => [
    if (image != null) image!,
    if (video != null) video!,
  ];
}

/// Pairing key of one row: the album sequence when the name carries it, else
/// the stored item index.
///
/// The index is only a fallback on purpose. The album name is written from the
/// same 1-based index at save time and survives every later change of the
/// row's extension, MIME type or item type, so a still and its motion clip keep
/// pairing even when the two rows disagree about `itemIndex`.
String pairingKeyOf(HistoryFile file) {
  final sequence = albumSequenceOf(file.filename);
  if (sequence != null) return 'n$sequence';
  return 'i${file.itemIndex}';
}

/// Group saved rows into the entries the UI counts and shows.
///
/// Rules, applied to one post at a time:
/// * rows whose album name (or, without one, item index) matches belong to the
///   same entry;
/// * a group pairs into one Live entry only when it holds exactly one image and
///   exactly one video, so an ambiguous set is never silently merged;
/// * two rows that both carry a `prov:pairId` must agree before they pair,
///   mirroring the rebuild scan;
/// * the still comes before its clip and entries keep their input order.
List<SavedMediaEntry> pairSavedMedia(Iterable<HistoryFile> files) {
  final order = <String>[];
  final groups = <String, List<HistoryFile>>{};
  for (final file in files) {
    final key = pairingKeyOf(file);
    final group = groups.putIfAbsent(key, () {
      order.add(key);
      return <HistoryFile>[];
    });
    group.add(file);
  }

  final entries = <SavedMediaEntry>[];
  for (final key in order) {
    final group = groups[key]!;
    final images = group.where((f) => f.isImage).toList();
    final videos = group.where((f) => !f.isImage).toList();
    if (images.length == 1 && videos.length == 1 && _samePairId(images[0], videos[0])) {
      entries.add(
        SavedMediaEntry(
          itemIndex: _itemIndexOf(images[0], videos[0]),
          image: images[0],
          video: videos[0],
        ),
      );
      continue;
    }
    for (final file in group) {
      entries.add(
        SavedMediaEntry(
          itemIndex: file.itemIndex,
          image: file.isImage ? file : null,
          video: file.isImage ? null : file,
        ),
      );
    }
  }
  return entries;
}

/// How many entries [files] hold: a Live photo's still plus clip count as one.
int savedMediaEntryCount(Iterable<HistoryFile> files) =>
    pairSavedMedia(files).length;

/// Both rows may carry `prov:pairId`; they only conflict when both are set and
/// differ (old rows have none at all).
bool _samePairId(HistoryFile image, HistoryFile video) {
  final a = image.pairId;
  final b = video.pairId;
  if (a == null || a.isEmpty || b == null || b.isEmpty) return true;
  return a == b;
}

int _itemIndexOf(HistoryFile image, HistoryFile video) {
  final index = image.itemIndex >= 1 ? image.itemIndex : video.itemIndex;
  if (index >= 1) return index;
  return albumSequenceOf(image.filename) ?? albumSequenceOf(video.filename) ?? 0;
}
