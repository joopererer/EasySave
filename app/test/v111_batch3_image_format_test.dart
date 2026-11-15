// Copyright 2026 EasySave. All rights reserved.
// v1.11 batch 3: 我的 → 设置 → 下载 → 图片格式.
//
//   compat   (default) — the v1.10.3 ladder: jpeg transcode first, then an
//                        original this device can decode, then the preview copy
//                        marked 「非原图」;
//   original           — the original bytes win (HEIC / WebP / AVIF included),
//                        saved even when this device cannot show them, with the
//                        completion note saying so;
//   jpeg               — only a jpeg result, and when there is none the compat
//                        ladder plus 「未取得 JPEG，已按兼容优先保存」.
//
// "拿不到 jpg" is answered by the candidate list, "本机无法显示" by the saved
// file's container — a name check, never a decode.

import 'package:easysave/services/backup/backup_model.dart';
import 'package:easysave/services/backup/backup_service.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/image_format_preference.dart';
import 'package:easysave/services/media_content_type.dart';
import 'package:easysave/services/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// An item whose originals are the token the parser produced. One token per
/// item, as the parser really delivers it: the same token serves the HEIC (or
/// WebP) original, its JPEG transcode and its preview copy.
const _tokenA = 'spectrum/1040g0k031abcdefghij005n7t8q9r0';
const _tokenB = 'spectrum/1040g0k031abcdefghij005n7t8q9r1';
const _heicOriginal = 'https://sns-img-qc.xhscdn.com/$_tokenA';
const _heicJpeg =
    'https://sns-img-qc.xhscdn.com/$_tokenA?imageView2/format/jpg/q/100';
const _webpOriginal = 'https://sns-img-qc.xhscdn.com/$_tokenB';
const _jpgOriginal = 'https://sns-img-qc.xhscdn.com/pic/a.jpg';
const _preview = 'https://sns-webpic-qc.xhscdn.com/$_tokenA!nd_prv_wlteh_webp_3';

String _first(List<String> urls) => urls.first;

bool _isJpeg(String url) {
  final label = candidateLabelOf(url);
  return label.contains(':') && label.split(':').last == 'jpg';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('the candidate ladder', () {
    test('compat keeps the v1.10.3 order: jpeg transcode first', () {
      final urls = stillCandidatesFor(
        [_heicOriginal, _heicJpeg],
        formatPref: ImageFormatPreference.compat,
      );
      expect(_first(urls), _heicJpeg);
      expect(urls, contains(_heicOriginal));
    });

    test('original puts the original bytes first, HEIC included', () {
      final urls = stillCandidatesFor(
        [_heicOriginal, _heicJpeg],
        formatPref: ImageFormatPreference.original,
      );
      expect(_first(urls), _heicOriginal);
      expect(
        urls,
        contains(_heicJpeg),
        reason: 'the transcode stays as a fallback, not as the first try',
      );
    });

    test('original keeps the WebP original ahead of any transcode', () {
      final urls = stillCandidatesFor(
        [_webpOriginal, _heicJpeg],
        formatPref: ImageFormatPreference.original,
      );
      expect(_first(urls), _webpOriginal);
    });

    test('original still ends with the preview copy', () {
      final urls = stillCandidatesFor(
        [_heicOriginal, _preview],
        formatPref: ImageFormatPreference.original,
      );
      expect(_first(urls), _heicOriginal);
      expect(
        urls.last,
        _preview,
        reason: 'a preview still answers when every original failed',
      );
    });

    test('jpeg accepts only a jpeg candidate', () {
      final urls = stillCandidatesFor(
        [_heicOriginal, _heicJpeg],
        formatPref: ImageFormatPreference.jpeg,
      );
      expect(urls, hasLength(1));
      expect(_isJpeg(_first(urls)), isTrue);
      expect(
        stillFormatFellBack(
          [_heicOriginal, _heicJpeg],
          formatPref: ImageFormatPreference.jpeg,
        ),
        isFalse,
      );
    });

    test('jpeg takes a parser-delivered jpg as well', () {
      final urls = stillCandidatesFor(
        [_jpgOriginal],
        formatPref: ImageFormatPreference.jpeg,
      );
      expect(urls, [_jpgOriginal]);
    });

    test('jpeg with a HEIC original can ask the CDN for a jpeg of it', () {
      final source = [_heicOriginal];
      final urls = stillCandidatesFor(
        source,
        formatPref: ImageFormatPreference.jpeg,
      );
      expect(urls, hasLength(1));
      expect(
        _isJpeg(urls.single),
        isTrue,
        reason: 'the CDN transcode of the same token is a jpeg result',
      );
      expect(
        stillFormatFellBack(source, formatPref: ImageFormatPreference.jpeg),
        isFalse,
        reason: 'a jpeg result exists, so no fallback note',
      );
    });

    test('jpeg with a WebP original can ask the CDN for a jpeg of it', () {
      final source = [_webpOriginal];
      final urls = stillCandidatesFor(
        source,
        formatPref: ImageFormatPreference.jpeg,
      );
      expect(_isJpeg(urls.first), isTrue);
      expect(
        stillFormatFellBack(source, formatPref: ImageFormatPreference.jpeg),
        isFalse,
      );
    });

    test('every original failing leaves the preview copy in all three modes',
        () {
      final source = [_preview];
      for (final pref in ImageFormatPreference.values) {
        final urls = stillCandidatesFor(source, formatPref: pref);
        expect(urls, isNotEmpty, reason: 'pref=${pref.name}');
        expect(urls, contains(_preview), reason: 'pref=${pref.name}');
      }
      expect(
        stillFormatFellBack(source, formatPref: ImageFormatPreference.jpeg),
        isTrue,
        reason: 'a preview copy is not a JPEG result',
      );
    });
  });

  group('the completion note', () {
    DownloadBatch batchWith({
      required ImageFormatPreference pref,
      required String savedTitle,
      bool jpegFallback = false,
    }) => DownloadBatch(
      batchId: 'b1',
      album: 'EasySave',
      postUrl: 'https://www.xiaohongshu.com/explore/1',
      platform: 'xhs',
      postId: 'p1',
      formatPref: pref,
      jpegFallbackPlanned: jpegFallback,
      jobs: [
        DownloadJob(
          key: 'k1',
          label: '图片 1',
          filename: 'p1_1.jpg',
          urls: const ['https://sns-img-qc.xhscdn.com/a'],
          isImage: true,
          itemIndex: 1,
        )..state = JobState.done
         ..saved = true
         ..savedTitle = savedTitle,
      ],
    );

    test('original + a HEIC on disk asks the user to expect a preview-less '
        'file', () {
      expect(
        imageFormatCompletionNote(
          batchWith(
            pref: ImageFormatPreference.original,
            savedTitle: 'p1_1.heic',
          ),
        ),
        '已保存为原始格式，本机可能无法显示',
      );
    });

    test('original + a jpeg on disk says nothing', () {
      expect(
        imageFormatCompletionNote(
          batchWith(
            pref: ImageFormatPreference.original,
            savedTitle: 'p1_1.jpg',
          ),
        ),
        isNull,
      );
    });

    test('jpeg with a fallback says the save was compat', () {
      expect(
        imageFormatCompletionNote(
          batchWith(
            pref: ImageFormatPreference.jpeg,
            savedTitle: 'p1_1.jpg',
            jpegFallback: true,
          ),
        ),
        '未取得 JPEG，已按兼容优先保存',
      );
    });

    test('compat never adds a note', () {
      expect(
        imageFormatCompletionNote(
          batchWith(
            pref: ImageFormatPreference.compat,
            savedTitle: 'p1_1.heic',
            jpegFallback: true,
          ),
        ),
        isNull,
      );
    });

    test('the batch keeps the preference across a snapshot round trip', () {
      final batch = batchWith(
        pref: ImageFormatPreference.original,
        savedTitle: 'p1_1.heic',
        jpegFallback: true,
      );
      final restored = DownloadBatch.fromJson(batch.toJson());
      expect(restored.formatPref, ImageFormatPreference.original);
      expect(restored.jpegFallbackPlanned, isTrue);
    });

    test('a snapshot from before the setting reads as compat', () {
      final batch = batchWith(
        pref: ImageFormatPreference.jpeg,
        savedTitle: 'p1_1.jpg',
      );
      final json = Map<String, Object?>.from(batch.toJson())
        ..remove('formatPref')
        ..remove('jpegFallback');
      final restored = DownloadBatch.fromJson(json);
      expect(restored.formatPref, ImageFormatPreference.compat);
      expect(restored.jpegFallbackPlanned, isFalse);
    });
  });

  group('the setting', () {
    test('defaults to 兼容优先 and survives a save/load', () async {
      final settings = await AppSettings.load();
      expect(settings.imageFormat, ImageFormatPreference.compat);

      settings.imageFormat = ImageFormatPreference.original;
      await settings.save();

      final reloaded = await AppSettings.load();
      expect(reloaded.imageFormat, ImageFormatPreference.original);
    });

    test('an unknown stored value falls back to 兼容优先', () async {
      SharedPreferences.setMockInitialValues({'imageFormat': 'webp-only'});
      final settings = await AppSettings.load();
      expect(settings.imageFormat, ImageFormatPreference.compat);
    });

    test('every option has a label and a sentence for the settings page', () {
      for (final option in ImageFormatPreference.values) {
        expect(option.label, isNotEmpty);
        expect(option.description, isNotEmpty);
      }
      expect(ImageFormatPreference.compat.label, '兼容优先');
      expect(ImageFormatPreference.original.label, '原始格式');
      expect(ImageFormatPreference.jpeg.label, 'JPEG');
    });
  });

  group('the backup', () {
    test('BackupSettings carries the setting both ways', () {
      final settings = BackupSettings(imageFormat: 'original');
      final map = settings.toMap();
      expect(map['imageFormat'], 'original');
      expect(BackupSettings.fromMap(map).imageFormat, 'original');
    });

    test('a backup written before the setting reads as compat', () {
      final map = BackupSettings().toMap()..remove('imageFormat');
      expect(BackupSettings.fromMap(map).imageFormat, 'compat');
    });

    test('export → import round trip applies the preference', () async {
      final db = await HistoryDb.instance(dbPath: ':memory:');
      HistoryDb.setInstanceForTesting(db);
      addTearDown(HistoryDb.resetInstanceForTesting);

      final source = await AppSettings.load();
      source.imageFormat = ImageFormatPreference.original;
      final exported = await BackupService.exportBackup(
        db: db,
        settings: source,
      );

      final target = await AppSettings.load();
      target.imageFormat = ImageFormatPreference.compat;
      await BackupService.importBackup(
        exported,
        db: db,
        settings: target,
        restoreSettings: true,
      );

      expect(target.imageFormat, ImageFormatPreference.original);
    });
  });
}
