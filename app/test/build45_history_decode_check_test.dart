import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/history_decode_check.dart';
import 'package:easysave/services/image_decode_probe.dart';
import 'package:flutter_test/flutter_test.dart';

// v1.10.3: stills the album already holds are checked once, read-only and
// one file at a time, so a card can say "本机无法显示此格式" without ever
// entering the decode path that stalled the history page.

HistoryFile _file({
  required String filename,
  required String? mediaId,
  bool isImage = true,
  bool? undecodable,
  int itemIndex = 1,
}) => HistoryFile(
  filename: filename,
  savedAt: 1,
  status: FileStatus.found,
  itemIndex: itemIndex,
  isImage: isImage,
  mediaId: mediaId,
  undecodable: undecodable,
);

HistoryRecord _record(List<HistoryFile> files) => HistoryRecord(
  id: 1,
  postUrl: 'https://www.xiaohongshu.com/explore/6af3c278000000001c031f21',
  platform: 'xhs',
  postId: '6af3c278000000001c031f21',
  fileCount: files.length,
  files: files,
  createdAt: DateTime.fromMillisecondsSinceEpoch(1),
);

void main() {
  setUp(HistoryDecodeCheck.resetForTesting);
  tearDown(HistoryDecodeCheck.resetForTesting);

  group('which rows need a device decode check', () {
    test('a HEIC row with an album id and no verdict is checked', () {
      expect(
        needsDecodeCheck(_file(filename: 'p_1.heic', mediaId: '78001')),
        isTrue,
      );
      expect(
        needsDecodeCheck(_file(filename: 'p_1.HEIF', mediaId: '78002')),
        isTrue,
      );
      expect(
        needsDecodeCheck(_file(filename: 'p_1.avif', mediaId: '78003')),
        isTrue,
      );
    });

    test('a JPEG, a video or an already checked row is not', () {
      expect(
        needsDecodeCheck(_file(filename: 'p_1.jpg', mediaId: '78004')),
        isFalse,
      );
      expect(
        needsDecodeCheck(
          _file(filename: 'p_1.mp4', mediaId: '78005', isImage: false),
        ),
        isFalse,
      );
      expect(
        needsDecodeCheck(
          _file(filename: 'p_1.heic', mediaId: '78006', undecodable: false),
        ),
        isFalse,
      );
      expect(
        needsDecodeCheck(
          _file(filename: 'p_1.heic', mediaId: '78007', undecodable: true),
        ),
        isFalse,
      );
    });

    test('a row without a numeric album id is not probed', () {
      expect(needsDecodeCheck(_file(filename: 'p_1.heic', mediaId: null)),
          isFalse);
      expect(needsDecodeCheck(_file(filename: 'p_1.heic', mediaId: '')),
          isFalse);
      expect(
        needsDecodeCheck(_file(filename: 'p_1.heic', mediaId: 'asset-uuid')),
        isFalse,
      );
    });
  });

  group('the pass is bounded and read-only', () {
    test('an undecodable answer is recorded per row', () async {
      final probed = <String>[];
      HistoryDecodeCheck.probeForTesting = (mediaId) async {
        probed.add(mediaId);
        return mediaId == '78001'
            ? const ImageDecodeResult(
                ImageDecodeVerdict.undecodable,
                reason: 'decode_failed',
                decoder: 'bitmapfactory',
              )
            : const ImageDecodeResult(ImageDecodeVerdict.decodable);
      };

      final checked = await HistoryDecodeCheck.check(
        records: [
          _record([
            _file(filename: 'p_1.heic', mediaId: '78001'),
            _file(filename: 'p_1.mp4', mediaId: '78002', isImage: false),
            _file(filename: 'p_2.jpg', mediaId: '78003', itemIndex: 2),
          ]),
        ],
      );

      expect(checked, 1);
      expect(probed, ['78001']);
    });

    test('an unknown answer leaves the row untouched for the next pass',
        () async {
      HistoryDecodeCheck.probeForTesting =
          (mediaId) async => const ImageDecodeResult(
            ImageDecodeVerdict.unknown,
            reason: 'timeout',
          );
      final checked = await HistoryDecodeCheck.check(
        records: [
          _record([_file(filename: 'p_1.heic', mediaId: '78001')]),
        ],
      );
      expect(checked, 1);
    });

    test('one run never probes more than maxPerRun files', () async {
      var probed = 0;
      HistoryDecodeCheck.probeForTesting = (mediaId) async {
        probed++;
        return const ImageDecodeResult(ImageDecodeVerdict.decodable);
      };
      final rows = [
        for (var i = 0; i < 20; i++)
          _record([
            _file(filename: 'p_${i + 1}.heic', mediaId: '78$i', itemIndex: i + 1),
          ]),
      ];
      final checked = await HistoryDecodeCheck.check(records: rows);
      expect(checked, HistoryDecodeCheck.maxPerRun);
      expect(probed, HistoryDecodeCheck.maxPerRun);
    });
  });
}
