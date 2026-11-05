import 'dart:convert';

import 'package:easysave/core/models.dart';
import 'package:easysave/metadata/site_provenance.dart';
import 'package:easysave/services/ai_label_log.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:easysave/widgets/gallery_browser.dart';
import 'package:easysave/widgets/history_cards.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Instagram AI probe bridge', () {
    late List<String> lines;
    late DebugPrintCallback previous;
    setUp(() {
      lines = [];
      previous = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) lines.add(message);
      };
    });
    tearDown(() => debugPrint = previous);

    void send(String path, String name, String type, [Object? value]) {
      logUnknownAiLabel(
        'EasySaveIgAiProbe:${jsonEncode({'path': path, 'name': name, 'type': type, if (value != null) 'value': value})}',
      );
    }

    test('accepts root platform wording and discriminator enums', () {
      send(
        r'$.ai_label_info.attribution_label_text',
        'attribution_label_text',
        'string',
        'Made with AI',
      );
      send(r'$.ai_label_info.method', 'method', 'string', 'AI_CREATED');
      send(r'$.ai_label_info.enabled', 'enabled', 'boolean', true);
      expect(lines, hasLength(3));
      expect(lines.join('\n'), contains('Made with AI'));
      expect(lines.join('\n'), contains('AI_CREATED'));
    });

    test('rejects account, URL, query and non-enum diagnostic values', () {
      send(
        r'$.user.aigm_account_label_info.attribution_label_text',
        'attribution_label_text',
        'string',
        'PRIVATE_ACCOUNT',
      );
      send(
        r'$.ai_label_info.disclosure_url',
        'disclosure_url',
        'string',
        'https://private.invalid/?token=PRIVATE_QUERY',
      );
      send(r'$.ai_label_info.method', 'method', 'string', 'PRIVATE prose');
      send(
        r'$.ai_label_info.attribution_label_text',
        'attribution_label_text',
        'string',
        'https://private.invalid/?token=PRIVATE_QUERY',
      );
      expect(lines.join('\n'), isNot(contains('PRIVATE')));
      expect(lines.join('\n'), isNot(contains('https://')));
      expect(lines.join('\n'), isNot(contains('"value"')));
    });

    test('retains type-only root info diagnostics without AI in the name', () {
      send(r'$.ai_label_info.method', 'method', 'object');
      send(r'$.ai_label_info.nested.kind', 'kind', 'null');
      expect(lines, hasLength(2));
    });

    for (final entry in {
      'control-split URL': 'ht\ntps://private.invalid/resource',
      'control-split query': 'AI ?to\nken=PRIVATE_QUERY',
      'URL beyond truncation':
          'AI ${List.filled(80, '生').join()} https://private.invalid/resource',
      'control-split URL beyond truncation':
          'AI ${List.filled(80, '生').join()} ht\ntps://private.invalid/resource',
    }.entries) {
      test('rejects ${entry.key} before truncating platform wording', () {
        send(
          r'$.ai_label_info.attribution_label_text',
          'attribution_label_text',
          'string',
          entry.value,
        );
        expect(lines, hasLength(1));
        final encoded = lines.single.substring(lines.single.indexOf('{'));
        final record = jsonDecode(encoded) as Map<String, dynamic>;
        expect(record, {
          'path': r'$.ai_label_info.attribution_label_text',
          'name': 'attribution_label_text',
          'type': 'string',
        });
      });
    }

    test(
      'bounds root platform wording by Unicode characters and strips controls',
      () {
        send(
          r'$.ai_label_info.attribution_label_text',
          'attribution_label_text',
          'string',
          'AI\u0000\n\u007f\u0085 ${List.filled(80, '生').join()}',
        );
        expect(lines, hasLength(1));
        final encoded = lines.single.substring(lines.single.indexOf('{'));
        final record = jsonDecode(encoded) as Map<String, dynamic>;
        expect(record['value'], 'AI ${List.filled(57, '生').join()}');
        expect((record['value'] as String).runes.length, 60);
      },
    );
  });

  test('Instagram platform AI label uses the existing spec v0.1.6 mapping', () {
    SiteRegistry.useBuiltin();
    final post = ParsedPost.fromJson({
      'platform': 'instagram',
      'id': 'AIPlatform149',
      'url': 'https://www.instagram.com/p/AIPlatform149/',
      'items': [],
      'aiLabel': {'text': 'Made with AI', 'source': 'platform'},
    });
    final label = ParsedPost.fromJson(post.toJson()).aiLabel!;
    final provenance = buildSiteProvenance(
      platform: post.platform,
      capturedBy: 'EasySave',
      sourceId: post.id,
      sourceUrl: post.url,
      aiLabel: label.text,
      aiLabelSource: label.source,
      itemIndex: 1,
      itemCount: 1,
    );
    expect(provenance.aiLabel, 'Made with AI');
    expect(provenance.aiLabelSource, 'platform');
    expect(
      provenance.digitalSourceType,
      'http://cv.iptc.org/newscodes/digitalsourcetype/compositeWithTrainedAlgorithmicMedia',
    );
  });

  for (final ai in [true, false]) {
    testWidgets('Instagram saved card ${ai ? 'shows' : 'omits'} AI badge', (
      tester,
    ) async {
      var opened = false;
      final record = HistoryRecord(
        platform: 'instagram',
        postId: 'AIPlatform149',
        postUrl: 'https://www.instagram.com/p/AIPlatform149/',
        fileCount: 0,
        createdAt: DateTime(2026),
        aiLabel: ai ? 'Made with AI' : null,
        aiLabelSource: ai ? 'platform' : null,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 220,
              child: WaterfallPostCard(
                record: record,
                onTap: () => opened = true,
              ),
            ),
          ),
        ),
      );
      expect(find.text('AI'), ai ? findsOneWidget : findsNothing);
      if (ai) {
        await tester.tap(find.text('AI'));
        await tester.pumpAndSettle();
        expect(find.text('Made with AI'), findsOneWidget);
        expect(find.text('平台识别'), findsOneWidget);
        expect(opened, isFalse);
      }
    });

    testWidgets('Instagram saved gallery ${ai ? 'shows' : 'omits'} AI badge', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: GalleryBrowserPage(
            items: const [],
            authorName: '',
            title: 'Instagram fixture',
            platform: 'instagram',
            postUrl: '',
            aiLabel: ai ? 'Made with AI' : null,
            aiLabelSource: ai ? 'platform' : null,
          ),
        ),
      );
      expect(find.text('AI'), ai ? findsOneWidget : findsNothing);
      if (ai) {
        await tester.tap(find.text('AI'));
        await tester.pumpAndSettle();
        expect(find.text('Made with AI'), findsOneWidget);
        expect(find.text('平台识别'), findsOneWidget);
      }
    });
  }
}
