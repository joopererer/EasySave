// Copyright 2026 EasySave. All rights reserved.
// Unit tests for v1.7.1: bubble auto-hide setting and service sync.

import 'package:easysave/services/bubble_service.dart';
import 'package:easysave/services/settings.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppSettings.bubbleAutoHide', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('defaults to true', () async {
      final settings = await AppSettings.load();
      expect(settings.bubbleAutoHide, isTrue);
    });

    test('persists false when toggled off', () async {
      final settings = await AppSettings.load();
      settings.bubbleAutoHide = false;
      await settings.save();

      final reloaded = await AppSettings.load();
      expect(reloaded.bubbleAutoHide, isFalse);
    });

    test('persists true when toggled on', () async {
      SharedPreferences.setMockInitialValues({'bubbleAutoHide': false});
      final settings = await AppSettings.load();
      expect(settings.bubbleAutoHide, isFalse);

      settings.bubbleAutoHide = true;
      await settings.save();

      final reloaded = await AppSettings.load();
      expect(reloaded.bubbleAutoHide, isTrue);
    });

    test('collection properties remain modifiable', () async {
      final settings = await AppSettings.load();
      // Verify v1.7 collection bug does not recur (must be mutable list).
      expect(() => settings.usedAlbumNames.add('TestAlbum'), returnsNormally);
      expect(settings.usedAlbumNames, contains('TestAlbum'));
    });
  });

  group('BubbleService.updateAutoHide', () {
    final List<MethodCall> calls = [];

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('easysave/bubble'),
        (MethodCall call) async {
          calls.add(call);
          return null;
        },
      );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('easysave/bubble'),
        null,
      );
    });

    test('invokes updateAutoHide with enabled: true', () async {
      await BubbleService.updateAutoHide(true);
      expect(calls, hasLength(1));
      expect(calls.first.method, equals('updateAutoHide'));
      expect(calls.first.arguments, equals({'enabled': true}));
    });

    test('invokes updateAutoHide with enabled: false', () async {
      await BubbleService.updateAutoHide(false);
      expect(calls, hasLength(1));
      expect(calls.first.method, equals('updateAutoHide'));
      expect(calls.first.arguments, equals({'enabled': false}));
    });
  });
}
