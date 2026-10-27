import 'package:easysave/widgets/gallery_browser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('history viewer starts with nothing selected', () {
    expect(initialGallerySelection(null), isEmpty);
  });

  test('explicit selection keeps original post item indices', () {
    final sel = initialGallerySelection({2, 3, 4});
    expect(sel, {2, 3, 4});
  });

  test('result is a copy, not the caller set', () {
    final src = <int>{1};
    final sel = initialGallerySelection(src)..add(5);
    expect(src, {1});
    expect(sel, {1, 5});
  });
}
