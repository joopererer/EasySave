# Build 34 handoff: three v1.10 experience fixes

## Delivery status

- Three display problems fixed, each with widget/unit tests; the parser module
  is untouched this round.
- Dependencies moved to provenance-spec **0.1.9** and provenance_dart
  **0.2.5** in a separate commit (`0e367c1`), because both were released.
  The new Douyin rules stay **unused** by the App.
- Device verification is **pending** for everything below. Nothing here claims
  a device result; the checks are widget/unit tests plus APK-level inspection.

## 1. A new history cover flashed a black frame

**Cause.** The cover area held nothing while the MediaStore thumbnail was
requested and decoded: `VerifiedAssetImage` returned an empty `SizedBox` during
the existence check and an `Image` with no placeholder/frame afterwards, so the
card's dark backing (and the pure black of the surrounding chrome in dark mode)
showed through for a frame. Nothing cross-faded either, so the first decoded
frame appeared as a jump.

**Changes.**

- `app/lib/widgets/progressive_asset_image.dart` (new): a cover is now
  placeholder -> system thumbnail -> sharp tier, each tier an
  `AnimatedOpacity` over `progressiveImageFade` (150 ms). A tier whose frame is
  already in the image cache is painted in the *same* frame with **no** fade and
  no blank frame, so list churn never flashes.
  The synchronous delivery path is what makes an existing cover immune to an
  insertion: `ImageStreamCompleter.addListener` replays the cached frame
  synchronously during `resolve()`, and the widget paints it in the build that
  follows.
- `app/lib/widgets/verified_asset_image.dart`: renders
  `ProgressiveAssetImage`; while the existence check is still pending it shows
  the placeholder colour instead of an empty box; the tier providers are still
  value-equal across rebuilds (`AssetEntityImageProvider` /
  `ResizeImage` compare by value, `AssetEntity` by id), so the image cache and
  the gallery's pre-decode keep working.
- `app/lib/widgets/history_cards.dart`: `coverPlaceholderColor()` mixes the
  platform tag colour into the page surface; the remote `CoverImage` fallback of
  a saved-post cover also uses it.
- `app/lib/widgets/shared.dart`: `CoverImage`'s default loading placeholder
  changed from `black12` to the neutral surface tint (never black).
- Stable keys were already `wf-${record.id}` / `row-${record.id}` per card; they
  stay, and the crash-free path above means a masonry rebuild (which happens on
  insertion) no longer costs a decode or a blank frame.

**Tests.** `app/test/build34_cover_placeholder_test.dart`

- placeholder colour first (not black), then a fade: opacity is 0 before the
  frame, strictly between 0 and 1 at 75 ms, 1.0 after 150 ms, and the
  `AnimatedOpacity` duration is exactly `progressiveImageFade`.
- an already decoded cover paints in the first frame after an insertion and is
  not decoded again (`loads['1:thumb']`/`['2:thumb']` stay 1); a new cover stays
  tinted while its decode is held open.
- the real `HistoryPage` waterfall: save a third post, `reload()`, and the very
  first pumped frame already shows the pixels of covers 1 and 2 with no
  re-decode, while cover 3 is still tinted.
- `coverPlaceholderColor()` is never black and differs per platform.

## 2. A black gap while switching saved full-screen images

**Cause.** The viewer asked for the original bytes
(`AssetEntityImageProvider(isOriginal: true)`), i.e. a 5152x6864 Xiaohongshu
original decodes to ~134.9 MB in one shot and takes 0.4-0.5 s on the test host.
Switching therefore showed an empty page until the decode finished, and the huge
bitmaps evicted the neighbouring decoded images from the image cache.

**Changes.**

- `decodeTargetFor()` + `screenSizedAssetProvider()`: the viewer tier decodes
  the original bytes at the screen size (screen width/height x devicePixelRatio,
  same aspect ratio, `ResizeImage` with `ResizeImagePolicy.fit`), never at the
  original pixels.
- `systemThumbnailProvider()` under the sharp tier: the MediaStore thumbnail of
  the same box is painted as soon as it arrives, so a switch shows pixels
  immediately and the sharp tier replaces it silently. No loading indicator and
  no black frame.
- Zoom tier: `_ZoomableImageView` publishes "scale > 2.0" through a
  `ValueNotifier`; past the threshold the original is decoded and painted on
  top, and zooming back out removes the layer and evicts the provider from the
  image cache (`PaintingBinding.instance.imageCache.evict`).
- `DecodedImageKeeper` now enforces a byte budget of **decoded pixels**
  (width x height x 4 of what was really decoded) on top of its 5-entry limit,
  releasing the least recently kept first; the neighbours are pre-decoded at the
  same screen-size tier, so a pre-decode costs 5.9 MB instead of 134.9 MB.
- Videos and Live Photos keep their existing widgets and behaviour; only their
  decode size follows the same screen-size rule.

**Region decoding.** Tile/region decoding (Android `BitmapRegionDecoder`,
`SubsamplingScaleImageView`, `extended_image`/`photo_view` style) was evaluated
and **not** implemented in this build. Reason: the App renders Flutter
`ui.Image` layers inside `InteractiveViewer`, so region decoding would need a new
native bridge that returns tiles as raw pixels, a client-side tile cache, and a
custom painter with its own transform/gesture math; the cost and the risk of
untested interaction bugs (rotation, EXIF, Live Photo stills, selection mode)
are larger than the benefit over "screen-size default + original on zoom", which
is the behaviour the task allows as the fallback. Licences were only read for
ideas; no code from those projects was copied. If region decoding is revisited,
the natural shape is: native `BitmapRegionDecoder` -> `ui.decodeImageFromPixels`
tiles keyed by (mediaId, level, tileX, tileY) with an LRU byte budget.

**Decode benchmark (real 5152x6864 image, Windows host, Flutter test VM).**

A real JPEG (16.2 MB, noise content, produced once with ffmpeg) and a 342 KB PNG
of the same dimensions were decoded three times each, first with no target size
and then with the screen box 1080x1439 (`dart:ui.instantiateImageCodecWithSize`,
the same code path `ResizeImage` uses):

| source | tier | time | decoded size | decoded RAM |
|---|---|---|---|---|
| 5152x6864 JPEG (16.2 MB) | original | 403 / 462 / 426 ms | 5152x6864 | 134.9 MB |
| 5152x6864 JPEG (16.2 MB) | screen 1080x1439 | 241 / 296 / 220 ms | 1080x1439 | 5.9 MB |
| 5152x6864 PNG (342 KB) | original | 158 / 158 / 197 ms | 5152x6864 | 134.9 MB |
| 5152x6864 PNG (342 KB) | screen 1080x1439 | 190 / 205 / 311 ms | 1080x1439 | 5.9 MB |

Reading: for a real JPEG original the screen-size decode is ~1.7x faster and
uses **22.9x less decoded memory**. For a PNG the time is not better (Skia has no
sub-sampled PNG decode, so it decodes and then resamples) but the memory win is
the same - 22.9x - which is what removes the cache eviction that caused the black
gaps. The temporary benchmark test and the generated image were deleted after
recording these numbers.

**Tests.** `app/test/build34_large_image_decode_test.dart`

- `decodeTargetFor(5152x6864, 1080x2400)` stays inside the screen, keeps the
  aspect ratio, and is < 1/20 of the original pixel count; landscape and unknown
  dimensions handled.
- the viewer's sharp tier is a `ResizeImage` of the *original* bytes with
  `width`/`height` equal to `decodeTargetFor(...)` and `policy: fit`; its
  underlay is a non-original thumbnail of the same box; the original exists only
  as the zoom tier and is not built while not zoomed.
- with the sharp tier's decode held open, the underlay RawImage already paints,
  the sharp one does not, and no `CircularProgressIndicator` appears.
- driving the real `InteractiveViewer`'s `TransformationController` to 2.5x adds
  the original tier; back to 1.0 removes it *and* evicts it from the image cache.
- `DecodedImageKeeper` releases the oldest entry when the decoded-byte budget is
  exceeded.
- `app/test/build32_local_gallery_viewing_test.dart` was updated: the old
  expectation "a local original decodes without a thumbnail placeholder" is the
  behaviour this build intentionally replaces.

## 3. Ordering in the history "by author" view

**Changes.**

- `app/lib/services/creator_sort.dart` (new): pure ordering for
  `CreatorSortRow{id, name, postCount, lastSavedAt}`. Keys: post count, most
  recent save (the newest `savedAt` of any of the author's files, so a re-save
  moves the author up), and name. One direction flag for all three; default is
  most recent save, descending.
- Tie-breaks: for the name key, equal names fall back to the post count (more
  first) and then the latest save; for the other keys the name (locale order),
  the post count, the latest save, and finally the row id, so equal data never
  reshuffles between reloads.
- `app/lib/services/system_collation.dart` + `NativeCollation.kt` (new channel
  `easysave/text`): Dart has no collation, so names are ordered with Android's
  `java.text.Collator` for the current system locale (pinyin for a Chinese
  locale). The native side returns hex-encoded collation keys; only those keys
  cross the channel, never a name in a log. The caller falls back to the
  lower-cased name when the channel is unavailable (tests, other platforms).
  Keys are resolved before the first paint in `_reloadRecords`, so the creators
  grid does not visibly re-sort after loading.
- `AppSettings.creatorSort` / `creatorSortDescending` are persisted
  (`creatorSort`, `creatorSortDescending`); `HistoryPage` shows a dedicated
  "作者排序" menu in the creators view (three keys, a check mark on the active
  one, and a direction item).

**Tests.** `app/test/build34_creator_sort_test.dart`

- all three keys, both directions, with the pinyin key map (a < li < zhang);
  deterministic fallback without collation keys.
- equal names -> post count -> latest save, stable across repeated sorts.
- a creator with no located file still gets a deterministic place.
- widget test on the real `HistoryPage`: default order is most recent save
  descending; picking 帖子数 reorders; the direction item flips to ascending;
  picking 名字 with the mocked collation gives pinyin order; and the choice is
  written to SharedPreferences and read back by `AppSettings.load()`.
- `NativeCollationTest` (Robolectric/JUnit): Chinese names sort by pinyin and
  the encoded keys compare like the raw collation keys.

## Dependency upgrade (separate commit `0e367c1`)

- provenance-spec: submodule pointer moved from v0.1.8 to **v0.1.9**
  (`55c9c4c`), provenance_dart from v0.2.4 to **v0.2.5** (`4f03c2f`).
- 0.1.9 is additive (Douyin normalization vectors plus spec text). The Douyin
  rules are **not** enabled in the App.
- `app/test/provenance_spec_identity_test.dart` (renamed from
  `build31_spec_018_identity_test.dart`) now asserts `provenanceSpecVersion ==
  "0.1.9"`, runs every 0.1.8 *and* 0.1.9 vector through `normalizeUrl`, asserts
  that every older vector is unchanged, and scopes the App-level canonical URL
  check to the Xiaohongshu cases the App enables (Douyin vectors have ids but no
  enabled site rule).
- `app/analysis_options.yaml` now excludes `build/**` from analysis: the
  leftover Flutter test temp copies and the project-local Gradle/pub caches under
  `app/build` produced 63k of 66k findings from third-party copies. Source under
  `lib/` and `test/` is still fully analysed.

## Build 34 artifact

```
path   app/build/app/outputs/flutter-apk/EasySave-1.10.0-build34-release.apk
       (same file as app/build/app/outputs/flutter-apk/app-release.apk)
version 1.10.0 (versionName='1.10.0', versionCode='34'), package com.james.easysave
bytes  69,129,408
sha256 fe7610836ea7616ddd9a1919d9f1f03d6087cc40a09d12cc439973f79ffe8a01
signer C=US, O=Android, CN=Android Debug
       7ec6c14f1c8c9fff6de9a31fda73150c12db7c81c98ee8017960d838aecb3484 (same as build 33)
```

APK-level evidence that the new code is really in the artifact (no device run):

- `lib/arm64-v8a/libapp.so` contains the new creators menu labels
  `最近修改时间` and `帖子数` as UTF-16 string constants.
- `classes.dex` contains the new channel `easysave/text` and its method
  `collationKeys`, i.e. the native collation bridge is compiled in.
- `aapt2 dump badging` reports `versionCode='34' versionName='1.10.0'`,
  `application-label:'EasySave'`.

## Gates run for this build

- `flutter test` (all): **939 passed**, including the 13 new/changed tests in
  `build34_cover_placeholder_test.dart`, `build34_large_image_decode_test.dart`,
  `build34_creator_sort_test.dart` and the updated
  `build32_local_gallery_viewing_test.dart`.
- `flutter analyze`: exit 0, no errors (98 infos/warnings, all pre-existing;
  `build/**` is now excluded, which removed 63k findings that came from
  third-party copies inside `app/build`).
- `gradlew testDebugUnitTest`: BUILD SUCCESSFUL; `NativeCollationTest` 3/3
  (pinyin order, key encoding, empty input).
- `npm test` in `extension/`: 263 Vitest tests + 33 build checks pass.
- `flutter build apk --release`: built in 220 s, 65.9 MB.

Note on the environment: `node` was not on `PATH` in this shell, so
`D:\Program Files\nvm\v22.13.1` was prepended for the test runs (the Flutter
policy test shells out to `node.exe`); nothing system-wide was changed.
`JAVA_HOME` has a trailing semicolon in this environment, so it was set
explicitly for Gradle/apksigner.

## Device verification steps (not yet performed)

Install over the current build (same debug signing, so an in-place update
works; keep the data).

1. History cover (problem 1): open 历史, water-fall layout, then save a new post
   from another entry point. The new card's cover area must be the platform
   tinted placeholder first and then fade in - no black frame. Scroll through the
   existing cards while the new one decodes: the already decoded covers must not
   flash or reload. Repeat in dark mode (the black frame was most visible there).
2. Full-screen switching (problem 2): open a saved Xiaohongshu post with large
   originals (e.g. 5152x6864), swipe left/right quickly. Each switch must show
   the MediaStore thumbnail immediately and then sharpen silently, with no black
   gap and no spinner. Pinch past ~2x: the detail must become sharp; pinch back
   to fit: memory should drop again (check with `adb shell dumpsys meminfo
   com.james.easysave` before/after, without `run-as` and without reading app
   private files).
3. Creators ordering (problem 3): 历史 → 创作者. Default order is most recent
   save first. Switch to 帖子数, then 名字 (a Chinese-locale device orders by
   pinyin), toggle 正序/倒序 each time; kill and reopen the App: the last choice
   must be remembered.
4. Video and Live Photo pages must look and behave exactly as before (they were
   not touched beyond the shared decode-size rule).

Reported results remain "pending device verification" until the user runs the
steps above.

## Signing key of the release APKs (build 33 and build 34)

Verified from the artifact, without reading any key material:

```
$ apksigner verify --print-certs app/build/app/outputs/flutter-apk/EasySave-1.10.0-build33-release.apk
Signer #1 certificate DN: C=US, O=Android, CN=Android Debug
Signer #1 certificate SHA-256 digest: 7ec6c14f1c8c9fff6de9a31fda73150c12db7c81c98ee8017960d838aecb3484
```

(The build 34 APK prints the same DN and digest.)

- The release APK is signed with the **Android debug key**, not a release key.
  `app/android/app/build.gradle.kts` sets
  `buildTypes.release.signingConfig = signingConfigs.getByName("debug")`, and
  there is no `key.properties`, no `*.jks`/`*.keystore`, and no keystore
  configuration anywhere in the repository.
- The key file is the standard debug keystore outside the repository, at
  `%USERPROFILE%\.android\debug.keystore` (on this machine
  `C:\Users\<user>\.android\debug.keystore`), alias `androiddebugkey`, whose
  certificate SHA-256 equals the digest printed above (`7E:C6:C1:4F:...:34:84`).
  Only the certificate fingerprint was read; the key content was not opened or
  printed.
- Consequence for v1.10: build 34 (and every earlier build) can only be updated
  in place by an APK signed with the same debug key. Signing is **not** changed
  in this build; whether the v1.10 public release uses a real release key (which
  would make the current installs require an uninstall, and would need the
  keystore kept outside the repository) is the user's decision.