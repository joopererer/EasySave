// Copyright 2026 EasySave. All rights reserved.
// Unit tests for v1.7.1 bug fix: bubble auto-start reconciliation and sync.

import 'package:easysave/services/bubble_service.dart';
import 'package:easysave/services/settings.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BubbleService.ensureStarted', () {
    final List<String> channelMethodCalls = [];
    bool mockHasPermission = true;
    bool mockIsRunning = false;
    bool mockStartResult = true;

    setUp(() {
      channelMethodCalls.clear();
      mockHasPermission = true;
      mockIsRunning = false;
      mockStartResult = true;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('easysave/bubble'),
        (MethodCall call) async {
          channelMethodCalls.add(call.method);
          switch (call.method) {
            case 'hasPermission':
              return mockHasPermission;
            case 'isRunning':
              return mockIsRunning;
            case 'start':
              return mockStartResult;
            default:
              return null;
          }
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

    test('1. 设置开启 + 有权限时启动', () async {
      SharedPreferences.setMockInitialValues({'bubbleEnabled': true});
      mockHasPermission = true;
      mockIsRunning = false;

      await BubbleService.ensureStarted();

      expect(channelMethodCalls, contains('hasPermission'));
      expect(channelMethodCalls, contains('isRunning'));
      expect(channelMethodCalls, contains('start'));

      final settings = await AppSettings.load();
      expect(settings.bubbleEnabled, isTrue);
    });

    test('1b. 设置开启 + 有权限且已在运行时不重复启动', () async {
      SharedPreferences.setMockInitialValues({'bubbleEnabled': true});
      mockHasPermission = true;
      mockIsRunning = true;

      await BubbleService.ensureStarted();

      expect(channelMethodCalls, contains('hasPermission'));
      expect(channelMethodCalls, contains('isRunning'));
      expect(channelMethodCalls, isNot(contains('start')));

      final settings = await AppSettings.load();
      expect(settings.bubbleEnabled, isTrue);
    });

    test('2. 设置开启 + 无权限时同步关闭开关', () async {
      SharedPreferences.setMockInitialValues({'bubbleEnabled': true});
      mockHasPermission = false;
      final initialTicks = BubbleService.stateTick.value;

      await BubbleService.ensureStarted();

      expect(channelMethodCalls, contains('hasPermission'));
      expect(channelMethodCalls, isNot(contains('start')));

      // Setting must be synchronized to false
      final settings = await AppSettings.load();
      expect(settings.bubbleEnabled, isFalse);

      // stateTick should be bumped so UI listeners refresh
      expect(BubbleService.stateTick.value, greaterThan(initialTicks));
    });

    test('3. 设置关闭时不启动', () async {
      SharedPreferences.setMockInitialValues({'bubbleEnabled': false});
      mockHasPermission = true;
      mockIsRunning = false;

      await BubbleService.ensureStarted();

      expect(channelMethodCalls, isNot(contains('start')));
      expect(channelMethodCalls, isNot(contains('hasPermission')));

      final settings = await AppSettings.load();
      expect(settings.bubbleEnabled, isFalse);
    });
  });

  group('bubblePreviewSticky setting', () {
    test('defaults to false when not present', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = await AppSettings.load();
      expect(settings.bubblePreviewSticky, isFalse);
    });

    test('persists true value when saved', () async {
      SharedPreferences.setMockInitialValues({'bubblePreviewSticky': true});
      final settings = await AppSettings.load();
      expect(settings.bubblePreviewSticky, isTrue);

      settings.bubblePreviewSticky = false;
      await settings.save();

      final reloaded = await AppSettings.load();
      expect(reloaded.bubblePreviewSticky, isFalse);
    });
  });
}

