import 'dart:async';

import 'package:easysave/pages/mine_page.dart';
import 'package:easysave/services/auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final queried = <String>[];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    queried.clear();
  });
  tearDown(() => cookieNamesReaderForTesting = null);

  test('no XHS session cookie on either domain is "not logged in" without a page load',
      () async {
    cookieNamesReaderForTesting = (url) async {
      queried.add(Uri.parse(url).host);
      return ['a1', 'webId', 'xsecappid']; // non-session cookies only
    };
    expect(await probeXhsSessions(entry: 'test'), SessionStatus.invalid);
    expect(queried.toSet(), containsAll(['www.xiaohongshu.com', 'www.rednote.com']));
    expect((await loadXhsDomainStatuses()).values, everyElement(SessionStatus.invalid));
  });

  test('a session cookie name on either domain is detected', () async {
    cookieNamesReaderForTesting = (url) async =>
        Uri.parse(url).host.contains('rednote') ? ['web_session'] : <String>[];
    expect(await hasSessionCookie('xhs'), isTrue);
    cookieNamesReaderForTesting = (_) async => throw StateError('store');
    expect(await hasSessionCookie('xhs'), isNull);
  });

  test('page state decides between logged in and unknown when a cookie exists', () {
    expect(combineXhsSessionStates([true, null]), SessionStatus.valid);
    expect(combineXhsSessionStates([null, null]), SessionStatus.unknown);
    expect(combineXhsSessionStates([false, null]), SessionStatus.unknown);
    expect(combineXhsSessionStates([false, false]), SessionStatus.invalid);
  });

  test('other platforms follow the cookie-name rule', () async {
    cookieNamesReaderForTesting = (_) async => <String>[];
    expect(await checkLogin('instagram'), isFalse);
    cookieNamesReaderForTesting = (_) async => ['sessionid'];
    expect(await checkLogin('instagram'), isTrue);
  });

  testWidgets('unknown XHS state offers recheck and login; recheck checks XHS only',
      (tester) async {
    PackageInfo.setMockInitialValues(appName: 'EasySave', packageName: 'com.james.easysave',
        version: '1.10.0', buildNumber: '32', buildSignature: '');
    const bubble = MethodChannel('easysave/bubble');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(bubble, (_) async => false);
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(bubble, null));
    cookieNamesReaderForTesting = (url) async {
      queried.add(Uri.parse(url).host);
      return <String>[];
    };
    var xhsChecks = 0;
    final recheck = Completer<SessionStatus>();
    await tester.pumpWidget(MaterialApp(
      home: MinePage(xhsSessionProbe: ({String entry = 'test'}) async {
        xhsChecks++;
        return xhsChecks == 1 ? SessionStatus.unknown : recheck.future;
      }),
    ));
    await tester.pumpAndSettle();

    Finder row(String label) => find.ancestor(of: find.text(label), matching: find.byType(ListTile));
    final xhs = row('小红书');
    expect(find.descendant(of: xhs, matching: find.text('重新检查')), findsOneWidget);
    expect(find.descendant(of: xhs, matching: find.text('去登录')), findsOneWidget);
    expect(find.descendant(of: row('Instagram'), matching: find.text('去登录')), findsOneWidget);

    final otherQueries = queried.where((h) => !h.contains('xiaohongshu') && !h.contains('rednote')).length;
    await tester.tap(find.descendant(of: xhs, matching: find.text('重新检查')));
    await tester.pump();
    expect(find.descendant(of: row('小红书'), matching: find.text('检查中…')), findsOneWidget);
    expect(find.text('检查中…'), findsOneWidget, reason: 'only the XHS row is checking');
    expect(xhsChecks, 2);

    recheck.complete(SessionStatus.invalid);
    await tester.pumpAndSettle();
    expect(find.text('检查中…'), findsNothing);
    expect(queried.where((h) => !h.contains('xiaohongshu') && !h.contains('rednote')).length,
        otherQueries, reason: 'other platforms are not checked again');
    expect(find.descendant(of: row('小红书'), matching: find.text('去登录')), findsOneWidget);
    expect(find.text('重新检查'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
