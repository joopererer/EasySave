import 'package:easysave/core/error_copy.dart';
import 'package:easysave/core/models.dart';
import 'package:easysave/services/parser_hooks.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('MEDIA_UNAVAILABLE copy sends the user to the login page', () {
    final copy = errorCopyFor(ParseErrorCode.mediaUnavailable);
    expect(copy.action, ErrorAction.goLogin);
    expect(copy.message, contains('我的'));
    expect(copy.message, contains('Instagram'));
  });

  test('[IgParse] diagnostic accepts only the fixed vocabulary', () {
    final lines = <String>[];
    final previous = debugPrint;
    debugPrint = (message, {wrapWidth}) {
      if (message != null) lines.add(message);
    };
    addTearDown(() => debugPrint = previous);

    logIgParseDiagnostic(
      '[IgParse] source=api mediaType=carousel items=16 loginWall=0',
    );
    logIgParseDiagnostic(
      '[IgParse] source=og_meta mediaType=video items=0 loginWall=1',
    );
    // A page address, extra key or a value outside the vocabulary is dropped.
    logIgParseDiagnostic(
      '[IgParse] source=api mediaType=image items=1 loginWall=0 '
      'https://www.instagram.com/p/PRIVATE/?igsh=PRIVATE',
    );
    logIgParseDiagnostic(
      '[IgParse] source=cookie mediaType=image items=1 loginWall=0',
    );
    logIgParseDiagnostic('IgParse source=api mediaType=image items=1 loginWall=0');

    expect(lines, hasLength(2));
    expect(
      lines[0],
      contains('source=api mediaType=carousel items=16 loginWall=0'),
    );
    expect(
      lines[1],
      contains('source=og_meta mediaType=video items=0 loginWall=1'),
    );
    for (final line in lines) {
      expect(line, isNot(contains('PRIVATE')));
      expect(line, isNot(contains('http')));
    }
  });
}
