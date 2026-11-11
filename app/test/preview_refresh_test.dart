import 'dart:async';
import 'dart:io';
import 'package:easysave/core/models.dart';
import 'package:easysave/pages/preview_page.dart';
import 'package:easysave/widgets/shared.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/verified_media.dart';
import 'package:easysave/widgets/verified_asset_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() { sqfliteFfiInit(); databaseFactory = databaseFactoryFfi; });

  // The media load gate arms a deadline for every local request; the album
  // plugin has to answer so no platform call stays pending past the test.
  const photos = MethodChannel('com.fluttercandies/photo_manager');
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(photos, (_) async => null);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(photos, null);
  });

  test('missing MediaStore ID and query errors are not local files', () async {
    expect(await mediaExists('123', query: (_) async => null), isFalse);
    expect(await mediaExists('123', query: (_) async => throw StateError('query unavailable')), isFalse);
  });
  testWidgets('unverifiable local thumbnail falls back without broken image', (tester) async {
    final asset = AssetEntity(id: 'missing', typeInt: 1, width: 10, height: 10);
    await tester.pumpWidget(MaterialApp(home: VerifiedAssetImage(asset,
      verifyExistence: (_) async => false, fallback: const Text('network thumbnail'))));
    await tester.pumpAndSettle();
    expect(find.text('network thumbnail'), findsOneWidget);
    expect(find.byIcon(Icons.broken_image), findsNothing);
  });
  testWidgets('preview waits for local verification before building remote cover', (tester) async {
    final asset = AssetEntity(id: 'local', typeInt: 1, width: 10, height: 10);
    final result = Completer<bool>();
    await tester.pumpWidget(MaterialApp(home: PreviewItemCover(
      item: MediaItem(type: 'image', url: ''),
      platform: 'xhs', asset: asset, verifyExistence: (_) => result.future,
    )));
    expect(find.byType(CoverImage), findsNothing);
    result.complete(false);
    await tester.pumpAndSettle();
    expect(find.byType(CoverImage), findsOneWidget);
    expect(find.byIcon(Icons.broken_image), findsOneWidget);
  });
  test('fresh nonempty metadata merges; empty values and saved time survive', () async {
    final dir = await Directory.systemTemp.createTemp('preview_refresh');
    final db = await HistoryDb.instance(dbPath: '${dir.path}/history.db');
    final saved = DateTime(2020);
    await db.upsert(HistoryRecord(platform: 'xhs', postId: '123', postUrl: 'https://example.invalid/123',
      fileCount: 0, createdAt: saved, title: 'old title', caption: 'old caption', authorName: 'old author',
      aiLabel: 'old label', aiLabelSource: 'platform'));
    ParsedPost fresh({String? title, String? caption, AiLabel? ai}) => ParsedPost(
      platform: 'xhs', id: '123', url: 'https://example.invalid/123', author: PostAuthor(name: ''),
      items: [], title: title, caption: caption, aiLabel: ai);
    final merged = await db.mergeParsedPost(fresh(title: 'new title', caption: '', ai: const AiLabel(text: '作者声明：含ai生成内容', source: 'author')));
    expect(merged.title, 'new title');
    expect(merged.caption, 'old caption');
    expect(merged.author.name, 'old author');
    expect(merged.aiLabel?.source, 'author');
    final again = await db.mergeParsedPost(fresh(title: ' ', caption: null));
    expect(again.aiLabel?.text, '作者声明：含ai生成内容');
    expect(again.title, 'new title');
    final stored = (await db.getByPostId('123'))!;
    expect(stored.aiLabel, again.aiLabel?.text);
    expect(stored.createdAt, saved);
  });
}
