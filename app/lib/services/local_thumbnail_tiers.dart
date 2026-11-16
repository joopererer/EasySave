// The two local thumbnail sizes of EasySave (v1.11 batch 3).
//
// Before this file every surface asked for its own size: the history covers
// 400, the creator card's four cells 400, the viewer's thumbnail strip 120 and
// the parse page's candidate grid 150. A file seen in one place was therefore a
// *different* cache key in another, and the same picture was decoded twice (or
// three times) at three sizes.
//
// Two tiers are enough:
//
//   * [small]  for cells a few dozen dp wide — the creator card's 2×2 thumbs,
//              the viewer's thumbnail strip, the parse page's candidate grid.
//              160 px square is 100 KB decoded: above the 120/150 the small
//              surfaces used, so nothing gets softer, and far below [medium].
//   * [medium] for the cover of a history card, which is up to half the screen
//              wide on a 3x device — the 帖子 waterfall, the 全部 waterfall and
//              the row layout. 400 px square is 640 KB decoded, the size the
//              covers already used, so the waterfall keeps its sharpness.
//
// The same file in the same tier is the same cache key, so a picture the user
// already saw in one mode is a cache hit in another — which is what the
// [ModeSwitch] `cache_hit` field reports.

import 'package:photo_manager/photo_manager.dart';

abstract final class LocalThumbnailTiers {
  static const ThumbnailSize small = ThumbnailSize.square(160);
  static const ThumbnailSize medium = ThumbnailSize.square(400);
}
