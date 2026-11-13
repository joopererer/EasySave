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
/// * two rows only pair when both carry the same `prov:pairId`, or when one
///   download wrote both (see [_samePairId]);
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

/// Both rows may carry `prov:pairId`; they only pair when they agree *and*
/// both carry one, or when the same download wrote both.
///
/// The single case this must never allow is the one that broke an Instagram
/// Reel: an old `…_1.jpg` cover from an earlier download left in the album next
/// to a freshly downloaded `…_1.mp4` shares the album sequence and shares
/// "no pairId", which used to turn two unrelated files into one Live entry and
/// point the video at the still. A Live pair written by one download either
/// carries the same `prov:pairId` on both rows (v1.10.1 and later) or was
/// written in one pass, which the save instant shows.
bool _samePairId(HistoryFile image, HistoryFile video) {
  final a = image.pairId;
  final b = video.pairId;
  final hasA = a != null && a.isNotEmpty;
  final hasB = b != null && b.isNotEmpty;
  if (hasA || hasB) return hasA && hasB && a == b;
  return (image.savedAt - video.savedAt).abs() <= kSameDownloadPairWindowMs;
}

/// Two rows written by one download land in the history together; a file left
/// over from an earlier download of the same post is minutes or days older.
const int kSameDownloadPairWindowMs = 60 * 1000;

int _itemIndexOf(HistoryFile image, HistoryFile video) {
  final index = image.itemIndex >= 1 ? image.itemIndex : video.itemIndex;
  if (index >= 1) return index;
  return albumSequenceOf(image.filename) ?? albumSequenceOf(video.filename) ?? 0;
}
