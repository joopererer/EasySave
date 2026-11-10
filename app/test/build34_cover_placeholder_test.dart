// v1.10 build 34 / problem 1: a new cover in the history list must never show
// an empty (black) frame, must fade in over ~150 ms, and inserting a post must
// not re-decode or blank the covers of the posts already on screen.

import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:easysave/pages/history_page.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/widgets/history_cards.dart';
import 'package:easysave/widgets/progressive_asset_image.dart';
import 'package:easysave/widgets/verified_asset_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Counts `loadImage` per (asset, tier) and can hold a tier's decode open.
class _TierProvider extends ImageProvider<_TierProvider> {
  _TierProvider(this.id, this.tier, this.loads, {this.gate, this.image});
  final String id;
  final String tier;
  final Map<String, int> loads;
  final Completer<void>? gate;
  final ui.Image? image;

  String get label => '$id:$tier';

  @override
  Future<_TierProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _TierProvider key,
    ImageDecoderCallback decode,
  ) {
    loads[label] = (loads[label] ?? 0) + 1;
    return OneFrameImageStreamCompleter(() async {
      await gate?.future;
      return ImageInfo(image: image!.clone());
    }());
  }

  @override
  bool operator ==(Object other) =>
      other is _TierProvider && other.id == id && other.tier == tier;

  @override
  int get hashCode => Object.hash(id, tier);
}

ui.Image? _frame;

Future<void> _prepareFrame(WidgetTester tester) async {
  _frame ??= await tester.runAsync(() => createTestImage(width: 8, height: 8));
}

AssetEntity _asset(String id) => AssetEntity(
  id: id,
  typeInt: AssetType.image.index,
  width: 1290,
  height: 1608,
  title: '${id}_1.jpg',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  final loads = <String, int>{};

  setUp(() {
    loads.clear();
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    VerifiedAssetImage.resetKnownPresentForTesting();
    VerifiedAssetImage.existenceForTesting = (_) async => true;
  });

  tearDown(() {
    VerifiedAssetImage.existenceForTesting = null;
    VerifiedAssetImage.providerForTesting = null;
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  });

  testWidgets(
    'a cover shows the platform placeholder, then fades in over 150 ms',
    (tester) async {
      await _prepareFrame(tester);
      final gate = Completer<void>();
      VerifiedAssetImage.providerForTesting = (asset, original, _) =>
          _TierProvider(asset.id, original ? 'original' : 'thumb', loads,
              gate: gate, image: _frame);

      const placeholder = Color(0xFF7A5A52);
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 120,
              height: 120,
              child: VerifiedAssetImage(
                _asset('a'),
                fallback: const Text('fallback'),
                placeholderColor: placeholder,
              ),
            ),
          ),
        ),
      );

      // Nothing decoded yet: the area is the placeholder colour, not black and
      // not an empty rectangle.
      ColoredBox placeholderBox() => tester.widget<ColoredBox>(
        find
            .descendant(
              of: find.byType(VerifiedAssetImage),
              matching: find.byType(ColoredBox),
            )
            .first,
      );
      expect(placeholderBox().color, placeholder);
      expect(placeholderBox().color, isNot(Colors.black));
      expect(placeholderBox().color.computeLuminance(), greaterThan(0.02));

      // The existence check resolves: the progressive cover appears with the
      // same placeholder while the thumbnail is still decoding.
      await tester.pump();
      expect(find.byType(ProgressiveAssetImage), findsOneWidget);
      expect(placeholderBox().color, placeholder);
      final sharp = find.byKey(const ValueKey('sharp'));
      expect(
        tester
            .widget<AnimatedOpacity>(
              find.descendant(
                of: sharp,
                matching: find.byType(AnimatedOpacity),
              ),
            )
            .opacity,
        0.0,
      );

      // Decode finishes: the frame fades in instead of popping in.
      await tester.runAsync(() async {
        gate.complete();
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 75));
      final mid = tester
          .widget<FadeTransition>(
            find.descendant(of: sharp, matching: find.byType(FadeTransition)),
          )
          .opacity
          .value;
      expect(mid, greaterThan(0.0));
      expect(mid, lessThan(1.0), reason: 'the fade is in progress');

      await tester.pump(progressiveImageFade);
      expect(
        tester
            .widget<FadeTransition>(
              find.descendant(of: sharp, matching: find.byType(FadeTransition)),
            )
            .opacity
            .value,
        1.0,
      );
      expect(
        tester
            .widget<AnimatedOpacity>(
              find.descendant(
                of: sharp,
                matching: find.byType(AnimatedOpacity),
              ),
            )
            .duration,
        progressiveImageFade,
      );
    },
  );

  testWidgets(
    'an already decoded cover paints in the first frame, even when the list '
    'is rebuilt by an insertion, and is not decoded again',
    (tester) async {
      await _prepareFrame(tester);
      final gate = Completer<void>();
      VerifiedAssetImage.providerForTesting = (asset, original, _) =>
          _TierProvider(asset.id, original ? 'original' : 'thumb', loads,
              gate: asset.id == '3' ? gate : null, image: _frame);

      Widget cover(String id) => SizedBox(
        width: 100,
        height: 100,
        child: VerifiedAssetImage(_asset(id), fallback: const SizedBox(),
            placeholderColor: const Color(0xFF334455)),
      );

      await tester.pumpWidget(
        MaterialApp(home: Row(children: [cover('1'), cover('2')])),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pumpAndSettle();
      expect(loads['1:thumb'], 1);
      expect(loads['2:thumb'], 1);

      // A new post is inserted in front of both: the widgets are rebuilt from
      // scratch (new positions), the neighbours must keep their pixels.
      await tester.pumpWidget(
        MaterialApp(home: Row(children: [cover('3'), cover('1'), cover('2')])),
      );
      await tester.pump();

      final images = tester.widgetList<RawImage>(find.byType(RawImage)).toList();
      expect(images.length, greaterThanOrEqualTo(3));
      // Covers 1 and 2 paint on this very first frame; the new one waits for
      // its decode and shows the placeholder colour (never black).
      final painted = images.where((i) => i.image != null).length;
      expect(painted, greaterThanOrEqualTo(2));
      final boxes = tester
          .widgetList<ColoredBox>(find.byType(ColoredBox))
          .map((b) => b.color)
          .toList();
      expect(boxes, contains(const Color(0xFF334455)));
      expect(loads['1:thumb'], 1, reason: 'the existing cover is not decoded');
      expect(loads['2:thumb'], 1);

      await tester.runAsync(() async {
        gate.complete();
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pumpAndSettle();
      expect(loads['3:thumb'], 1);
    },
  );

  testWidgets(
    'history waterfall: inserting a new post keeps the existing covers '
    'decoded and tinted, the new cover shows a placeholder first',
    (tester) async {
      await _prepareFrame(tester);
      SharedPreferences.setMockInitialValues({});
      HistoryDb.resetInstanceForTesting();
      GalleryLocatorService.instance.resetForTesting();
      DownloadManager.instance.clearBatchesForTesting();

      final gate = Completer<void>();
      VerifiedAssetImage.providerForTesting = (asset, original, _) =>
          _TierProvider(asset.id, original ? 'original' : 'thumb', loads,
              gate: asset.id == '3' ? gate : null, image: _frame);
      final locator = GalleryLocatorService.instance;
      locator.permissionReaderForTesting =
          () async => PermissionState.authorized;
      locator.albumReaderForTesting =
          () async => [_asset('1'), _asset('2'), _asset('3')];
      locator.presenceProbeForTesting = (_) async => true;

      const photos = MethodChannel('com.fluttercandies/photo_manager');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        photos,
        (_) async => 0,
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          photos,
          null,
        );
        GalleryLocatorService.instance.resetForTesting();
        HistoryDb.resetInstanceForTesting();
        DownloadManager.instance.clearBatchesForTesting();
      });

      Future<void> save(HistoryDb db, String id, String title, DateTime at) =>
          db.upsert(
            HistoryRecord(
              platform: 'xhs',
              postId: id,
              postUrl: 'https://www.xiaohongshu.com/explore/$id',
              title: title,
              fileCount: 1,
              createdAt: at,
              itemsJson: jsonEncode([
                {
                  'type': 'image',
                  'url': 'https://img.example/$id.jpg',
                  'width': 1290,
                  'height': 1608,
                },
              ]),
              files: [
                HistoryFile(
                  filename: '${id}_1.jpg',
                  savedAt: at.millisecondsSinceEpoch,
                  itemIndex: 1,
                  mediaId: id,
                  status: FileStatus.found,
                ),
              ],
            ),
          );

      late HistoryDb db;
      await tester.runAsync(() async {
        db = await HistoryDb.instance(dbPath: ':memory:');
        HistoryDb.setInstanceForTesting(db);
        await db.clear();
        await save(db, '1', 'First post', DateTime(2026, 1, 2, 9));
        await save(db, '2', 'Second post', DateTime(2026, 1, 2, 10));
      });

      await tester.pumpWidget(const MaterialApp(home: HistoryPage()));
      Future<void> settle() async {
        for (var i = 0; i < 12; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
        }
      }

      await settle();
      expect(find.text('First post'), findsOneWidget);
      expect(find.text('Second post'), findsOneWidget);
      expect(loads['1:thumb'], 1);
      expect(loads['2:thumb'], 1);

      // A newer post arrives while the page is open.
      await tester.runAsync(
        () => save(db, '3', 'Third post', DateTime(2026, 1, 2, 11)),
      );
      final state = tester.state<HistoryPageState>(find.byType(HistoryPage));
      unawaited(state.reload());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      // One frame only: covers 1 and 2 must already show their pixels.
      await tester.pump();

      expect(find.text('Third post'), findsOneWidget);
      RawImage coverOf(String id) => tester.widget<RawImage>(
        find
            .descendant(
              of: find.byKey(ValueKey('wf-$id')),
              matching: find.byType(RawImage),
            )
            .first,
      );
      expect(coverOf('1').image, isNotNull,
          reason: 'the existing cover paints without a blank frame');
      expect(coverOf('2').image, isNotNull);
      expect(loads['1:thumb'], 1,
          reason: 'an insertion does not re-decode an existing cover');
      expect(loads['2:thumb'], 1);

      // The new cover has not decoded yet: its area is tinted, never black.
      List<Color> coloursOf(String id) => tester
          .widgetList<ColoredBox>(
            find.descendant(
              of: find.byKey(ValueKey('wf-$id')),
              matching: find.byType(ColoredBox),
            ),
          )
          .map((b) => b.color)
          .toList();
      final newCoverColours = coloursOf('3');
      expect(newCoverColours, isNotEmpty);
      expect(newCoverColours.first, isNot(Colors.black));
      expect(newCoverColours.first.computeLuminance(), greaterThan(0.01));

      // Once its thumbnail tier is requested it still shows the tint while the
      // decode is held open.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
      expect(loads['3:thumb'], 1);
      expect(coverOf('3').image, isNull);
      expect(coloursOf('3').first, isNot(Colors.black));
      expect(loads['1:thumb'], 1);
      expect(loads['2:thumb'], 1);

      await tester.runAsync(() async {
        gate.complete();
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pumpAndSettle();
      expect(coverOf('3').image, isNotNull);
    },
  );

  testWidgets(
    'the cover placeholder is the platform tint, never a black area',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: ColoredBox(color: Color(0xFFEEEEEE))),
      );
      final context = tester.element(find.byType(ColoredBox).first);
      final base = coverPlaceholderColor(context, 'unknown-platform');
      final xhs = coverPlaceholderColor(context, 'xhs');
      expect(base, isNot(Colors.black));
      expect(base.computeLuminance(), greaterThan(0.02));
      expect(xhs, isNot(Colors.black));
      expect(xhs, isNot(base),
          reason: 'the platform colour tints the cover area');
    },
  );
}
