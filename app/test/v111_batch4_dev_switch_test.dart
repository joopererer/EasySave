// Copyright 2026 EasySave. All rights reserved.
// v1.11 batch 4: the "下一次下载模拟失败" switch is persisted and lives in the
// new 开发者选项 group.
//
// Build 51 kept the flag in the main engine's memory. A download started from
// the bubble or a share runs in the background engine, which never saw it, so
// no device log carried `simulated_failure` at all. The flag now travels
// through SharedPreferences — one file both engines read — while staying
// one-shot: the engine that consumes it clears it for the other one.

import 'package:easysave/pages/mine_page.dart';
import 'package:easysave/services/auth.dart';
import 'package:easysave/services/dev_download_failure.dart';
import 'package:easysave/services/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    DevDownloadFailure.resetForTesting();
  });

  tearDown(() async {
    await DevDownloadFailure.settleForTesting();
    DevDownloadFailure.resetForTesting();
    await DevDownloadFailure.settleForTesting();
  });

  group('the switch crosses engines', () {
    test('an engine reads the flag the other engine armed', () async {
      // Engine A (the UI) arms it.
      DevDownloadFailure.arm();
      await DevDownloadFailure.settleForTesting();

      // Engine B (bubble / share) starts with no memory of its own.
      DevDownloadFailure.forgetMemoryForTesting();
      expect(DevDownloadFailure.armed, isFalse);
      await DevDownloadFailure.refresh();
      expect(DevDownloadFailure.armed, isTrue,
          reason: 'the armed flag must reach the background engine');
      expect(DevDownloadFailure.take('bg-batch', firstFile: true), isTrue);
    });

    test('the engine that uses it disarms it for the other one', () async {
      DevDownloadFailure.arm();
      await DevDownloadFailure.settleForTesting();

      DevDownloadFailure.forgetMemoryForTesting();
      await DevDownloadFailure.refresh();
      expect(DevDownloadFailure.take('bg-batch', firstFile: true), isTrue);
      await DevDownloadFailure.settleForTesting();

      // Engine A comes back: the switch is used up, not armed again.
      DevDownloadFailure.forgetMemoryForTesting();
      await DevDownloadFailure.refresh();
      expect(DevDownloadFailure.armed, isFalse);
      expect(DevDownloadFailure.take('ui-batch', firstFile: true), isFalse);
    });

    test('an app restart keeps it armed until it triggers', () async {
      DevDownloadFailure.arm();
      await DevDownloadFailure.settleForTesting();

      // A new process: same stored flag, no memory.
      DevDownloadFailure.forgetMemoryForTesting();
      await DevDownloadFailure.refresh();
      expect(DevDownloadFailure.armed, isTrue,
          reason: 'a restart must not clear the switch');

      expect(DevDownloadFailure.take('after-restart', firstFile: true), isTrue);
      await DevDownloadFailure.settleForTesting();
      DevDownloadFailure.forgetMemoryForTesting();
      await DevDownloadFailure.refresh();
      expect(DevDownloadFailure.armed, isFalse);
    });

    test('switching it off by hand clears the stored flag', () async {
      DevDownloadFailure.arm();
      await DevDownloadFailure.settleForTesting();
      DevDownloadFailure.disarm();
      await DevDownloadFailure.settleForTesting();

      DevDownloadFailure.forgetMemoryForTesting();
      await DevDownloadFailure.refresh();
      expect(DevDownloadFailure.armed, isFalse);
      expect(DevDownloadFailure.take('later-batch', firstFile: true), isFalse);
    });

    test('only the first file of the batch is taken, once', () async {
      DevDownloadFailure.arm();
      await DevDownloadFailure.settleForTesting();
      DevDownloadFailure.forgetMemoryForTesting();
      await DevDownloadFailure.refresh();

      expect(DevDownloadFailure.take('b', firstFile: false), isFalse);
      expect(DevDownloadFailure.armed, isTrue, reason: 'still waiting for file 1');
      expect(DevDownloadFailure.take('b', firstFile: true), isTrue);
      expect(DevDownloadFailure.take('b', firstFile: true), isFalse);
    });
  });

  group('开发者选项', () {
    test('the reveal state is persisted with the other settings', () async {
      final settings = await AppSettings.load();
      expect(settings.developerOptionsVisible, isFalse,
          reason: 'normal users never see the group');
      settings.developerOptionsVisible = true;
      await settings.save();

      final reloaded = await AppSettings.load();
      expect(reloaded.developerOptionsVisible, isTrue);
    });

    testWidgets('seven taps on the version row reveal the group', (tester) async {
      PackageInfo.setMockInitialValues(
        appName: 'EasySave',
        packageName: 'com.james.easysave',
        version: '1.11.0',
        buildNumber: '52',
        buildSignature: '',
      );
      const channel = MethodChannel('easysave/bubble');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => false,
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));

      await tester.pumpWidget(
        MaterialApp(home: MinePage(xhsSessionProbe: ({String entry = 'test'}) async {
          return SessionStatus.invalid;
        })),
      );
      // The page keeps a spinner while it loads; pump a bounded number of
      // frames instead of waiting for the animations to stop.
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      await tester.scrollUntilVisible(
        find.byKey(const Key('version_entry')),
        300,
      );
      await tester.pump();

      expect(find.byKey(const Key('version_entry')), findsOneWidget);
      expect(find.byKey(const Key('simulate_download_failure')), findsNothing,
          reason: 'the group stays hidden by default');

      Future<void> tapVersion() async {
        await tester.ensureVisible(find.byKey(const Key('version_entry')));
        await tester.pump();
        await tester.tap(find.byKey(const Key('version_entry')));
        await tester.pump();
      }

      for (var i = 0; i < 6; i++) {
        await tapVersion();
      }
      expect(find.byKey(const Key('simulate_download_failure')), findsNothing,
          reason: 'six taps are not enough');

      await tapVersion();
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('开发者选项'), findsWidgets);
      await tester.scrollUntilVisible(
        find.byKey(const Key('simulate_download_failure')),
        200,
      );
      await tester.pump();
      expect(find.byKey(const Key('simulate_download_failure')), findsOneWidget);

      // The switch arms the persisted flag.
      await tester.ensureVisible(
        find.byKey(const Key('simulate_download_failure')),
      );
      await tester.pump();
      expect(
        tester.widget<SwitchListTile>(
          find.byKey(const Key('simulate_download_failure')),
        ).value,
        isFalse,
        reason: 'the switch starts off',
      );

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
