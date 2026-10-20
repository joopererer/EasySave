import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:easysave/metadata/xmp_jpeg.dart';

void main() {
  test('Read sidecar XMP file', () async {
    final testVectorsPath = p.normalize(p.join(
      Directory.current.path,
      '..',
      'docs',
      'provenance-spec',
      'test-vectors',
    ));
    
    final xmpFile = File(p.join(testVectorsPath, 'local-video.mp4.xmp'));
    print('XMP file exists: ${xmpFile.existsSync()}');
    
    if (xmpFile.existsSync()) {
      final content = await xmpFile.readAsString();
      print('XMP content:\n$content');
      
      // Parse it
      final xmp = parseXmpXml(content);
      print('\nParsed XMP: $xmp');
      
      if (xmp != null) {
        print('\nJSON:');
        print(xmp.toJson());
      }
    }
  });
}
