import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/live_pairs.dart';
import 'package:flutter_test/flutter_test.dart';

// v1.10.3: an Instagram Reel downloaded as `DflxolxpdHT_1.mp4` next to an old
// `DflxolxpdHT_1.jpg` cover from an earlier download was shown as ONE Live
// entry, and the video page then played the still. Same album sequence is not
// a pairing: the two rows must belong to the same download.

const _dayMs = 24 * 60 * 60 * 1000;

HistoryFile _row({
  required String filename,
  required bool isImage,
  required int savedAt,
  String? pairId,
  int itemIndex = 1,
  String? mediaId,
}) => HistoryFile(
  filename: filename,
  savedAt: savedAt,
  status: FileStatus.found,
  itemIndex: itemIndex,
  isImage: isImage,
  mediaId: mediaId,
  pairId: pairId,
);

void main() {
  group('an old still never pairs with a new download', () {
    test('old jpg cover + new mp4 of the same sequence stay two entries', () {
      final oldCover = _row(
        filename: 'DflxolxpdHT_1.jpg',
        isImage: true,
        savedAt: 1000,
        mediaId: '70001',
      );
      final freshVideo = _row(
        filename: 'DflxolxpdHT_1.mp4',
        isImage: false,
        savedAt: 1000 + 3 * _dayMs,
        mediaId: '78054',
      );

      final entries = pairSavedMedia([oldCover, freshVideo]);

      expect(entries, hasLength(2));
      expect(entries.where((e) => e.isLive), isEmpty);
      expect(entries.first.video, isNull,
          reason: 'the mp4 is its own entry, never a motion clip');
      expect(entries.last.video?.mediaId, '78054');
      expect(entries.last.video?.mediaId, isNot(oldCover.mediaId));
    });

    test('two rows written by one download still pair (legacy, no pairId)',
        () {
      const sameInstant = 5000;
      final entries = pairSavedMedia([
        _row(
          filename: '6aeff4780000000010011312_1.heic',
          isImage: true,
          savedAt: sameInstant,
        ),
        _row(
          filename: '6aeff4780000000010011312_1.mp4',
          isImage: false,
          savedAt: sameInstant,
        ),
      ]);

      expect(entries, hasLength(1));
      expect(entries.single.isLive, isTrue);
    });

    test('rows a few seconds apart still count as one download', () {
      final entries = pairSavedMedia([
        _row(
          filename: 'p_1.heic',
          isImage: true,
          savedAt: 10000,
        ),
        _row(
          filename: 'p_1.mp4',
          isImage: false,
          savedAt: 10000 + 4000,
        ),
      ]);
      expect(entries, hasLength(1));
      expect(entries.single.isLive, isTrue);
    });

    test('a pairId on one side only is not a pair', () {
      final entries = pairSavedMedia([
        _row(
          filename: 'p_1.jpg',
          isImage: true,
          savedAt: 100,
          pairId: 'p#1',
        ),
        _row(
          filename: 'p_1.mp4',
          isImage: false,
          savedAt: 100,
        ),
      ]);
      expect(entries.where((e) => e.isLive), isEmpty);
    });

    test('two different pairIds are not a pair', () {
      final entries = pairSavedMedia([
        _row(filename: 'p_1.jpg', isImage: true, savedAt: 100, pairId: 'p#1'),
        _row(filename: 'p_1.mp4', isImage: false, savedAt: 100, pairId: 'q#9'),
      ]);
      expect(entries.where((e) => e.isLive), isEmpty);
    });

    test('one download writes one pairId on both rows', () {
      final entries = pairSavedMedia([
        _row(filename: 'p_1.jpg', isImage: true, savedAt: 100, pairId: 'p#1'),
        _row(filename: 'p_1.mp4', isImage: false, savedAt: 100, pairId: 'p#1'),
      ]);
      expect(entries, hasLength(1));
      expect(entries.single.isLive, isTrue);
      expect(entries.single.cover.isImage, isTrue,
          reason: 'the still is the cover of the pair');
    });
  });

  group('the album sequence still groups unrelated posts correctly', () {
    test('a single still is one entry', () {
      final entries = pairSavedMedia([
        _row(filename: 'p_2.jpg', isImage: true, savedAt: 1, itemIndex: 2),
      ]);
      expect(entries.single.itemIndex, 2);
      expect(entries.single.isLive, isFalse);
    });

    test('two stills of one sequence never merge into a pair', () {
      final entries = pairSavedMedia([
        _row(filename: 'p_1.jpg', isImage: true, savedAt: 1),
        _row(filename: 'p_1.webp', isImage: true, savedAt: 1),
      ]);
      expect(entries, hasLength(2));
      expect(entries.where((e) => e.isLive), isEmpty);
    });
  });
}
