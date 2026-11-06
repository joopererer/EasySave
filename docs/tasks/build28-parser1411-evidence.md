# Build 28 / parser 1.4.11 corrective handoff

## Delivery status

The APK and parser both change. Install build 28, then check the parser channel
for **1.4.11 / manifestVersion 7**. The APK already embeds this parser. A parser-only
update does not fix the history database, selection mapping, retry UI or viewers.
Device verification remains pending; no result below is a device verification claim.

## 1. Saved file identity and history

- The old asynchronous locator put the requested sequence first, then tried every
  other file belonging to the post. Its provenance check compared platform/post
  but omitted itemIndex. The synchronous locator explicitly returned `pool.first`
  when the requested sequence was absent. This can turn several inferred rows
  into references to the same first image. The App preview uses this locator;
  the overlay's shared parser thumbnails do not use that substitution path.
- Both fallbacks now stop when the requested sequence is absent. Existing-ID,
  exact-name, path and sequence lookups validate available provenance including
  itemIndex; fallback album matching also validates platform and avoids assigning
  one asset to several items. Database lookups/merges accept platform aliases and
  scope identical post IDs to their platform.
- Cards, history media groups and viewer entries use saved file rows. A missing
  row or an unknown filename-only guess is excluded. The viewer no longer fills
  an empty saved-file list with the original remote item list. Remote metadata is
  retained for the corresponding saved index and for explicit parse previews.
- Legacy `inferHistoryFiles` can produce original-post-sized candidate rows, and
  old fuzzy association can promote them to repeated assets. This is a reproducible
  source of a first 9-file deletion count followed by 3 after deduplication/scan.
  **The supplied log has no XHS operation, so the exact persisted rows behind that
  particular first dialog cannot be established from this export.** Existing
  duplicate/zero-based repair remains active. Fully authorized scans drop only
  unbound unknown candidates proven absent; previously saved missing rows retain
  their missing state. This changes database records only, never album files.
  `removedPlaceholders` logs the scan cleanup count; the existing before/after
  repair log preserves row indices and presence of identity fields.
- Retained failed jobs are reconciled by platform/post/index/media type against
  successful jobs and committed/read history rows; stale errors are cleared and
  reconciled snapshots persisted. No SQLite read is added to the frequent batch
  polling path. State derives from current jobs; history distinguishes partial
  success from all-failed, and completed files clear older failure overlays.
- Tests reproduce the original wrong-first-image return before the fix and cover
  3-of-9 imports, matching counts, failed then successful writes/snapshots,
  platform isolation, placeholder cleanup, and a real history page with nine
  unbound remote candidates that cannot open a saved gallery.

## 2. SQLite and history timeout

- In `v30dl.log`, lines 7707–7740 repeatedly show 3/30-row reads taking roughly
  4.7–5.1 seconds while decoding takes 0–6ms and `repairCount=0`; line 7742 is the
  4-second UI deadline. This supports queue/I/O delay, not expensive JSON decoding
  or a repair transaction in that observed interval.
- There is one cached Dart store future per database path per engine. Android's
  installed `sqflite_android 2.4.2+3` uses a static native single-instance map for
  a path by default; two Dart engines do not necessarily mean two independent
  SQLite handles. The native database worker serializes operations. WAL,
  busy_timeout=5000 and synchronous=NORMAL were already configured before this
  patch, onConfigure and onOpen. They remain enabled; this is not a missing-WAL fix.
- An actual read amplification bug was reproduced: preload of unresolved media IDs
  notified listeners even when no asset was found, feeding the recent-history
  listener back into the same preload. Unchanged permission probes also notified.
  Preview listeners repeatedly merged and wrote identical metadata. These cycles
  are removed; recent and preview refreshes are coalesced and identical metadata
  writes skipped. Recent 3/30 reads share one 30-row snapshot in the listener.
- Reads return the repaired snapshot without waiting for its repair write lock.
  Persisted repair remains transactional and re-reads the current row; tests await
  `settleRepairs()` before checking durable raw rows. Downloads/album scans perform
  network, media file access and image decoding outside write transactions.
- History reads allow up to three 6-second waits with 200/400ms backoff. An overdue
  in-flight read is reused; a completed failed read starts a fresh attempt. The
  refresh controller's outer bound covers that budget. Last successful content is
  retained on transient failure; empty error-page retry actually reads again.
- `[HistoryDb] event=read/write engine=main/background waitMs=... ioMs=... busy=...`
  accompanies recent reads and transactional writes. Write wait measures entry to
  the transaction callback; ioMs measures its remaining SQL duration. The sqflite
  read API exposes combined native query/queue elapsed time, reported as ioMs with
  waitMs=0; it cannot separately measure native queue and disk time. `HistoryTiming`
  continues to report query/decode/repair stages. A zero read wait is not evidence
  that the native queue had no delay.
- Real file-backed SQLite test: another connection holds BEGIN IMMEDIATE through
  foreground reads for 12 rounds. Reads return the last committed snapshot within
  the unchanged test threshold, then observe subsequent commits. Separate tests
  cover bounded retry, late success and retained-content UI.

## 3. Parse retry, preparation and login recheck

- App and overlay ultimately call the same cached parser and `_run` headless
  WebView implementation, with the same manifest UA, shared CookieManager,
  domain selection and site timeout. They create separate WebView instances.
  Overlay can hit the cross-engine RAM cache while an App retry previously forced
  a fresh parse: `entry == retry` explicitly bypassed both history/cache paths.
  Retry now uses the same cache-first entry as input; only explicit refresh skips it.
- The WebView previously waited for `onLoadStop` before testing parser readiness.
  A usable XHS document could therefore wait on slow page subresources. XHS now
  also checks verified parser readiness during document progress, after confirming
  the final selected post domain/path. It still validates the parser result.
  The export contains **zero** XHS ParseWebView lines, so the exact mobile-network
  timeout stage is unproven; this change addresses a code-level blocking condition,
  not a claim about a captured XHS navigation failure.
- `[ParseWebView]` now includes final domain choice (original/alternate), timeout
  stage, loaded path category and selected domain. Existing `[XhsDomain]` records
  original/alias session selection reason. No full URL, query value or cookie is
  added. Short-link alias persistence no longer delays successful parse return.
- Before the batch exists, the real preview immediately shows each selected index
  as preparing. The real download sheet opens when the batch is registered, before
  snapshot/placeholder database work and enqueue completion. `[V16DL] event=prepare`
  distinguishes local-match from association database elapsed time. Failed items
  log `item failed index=<1-based> reason=HTTP_403/HTTP_404/TIMEOUT/POLICY/IMPORT/TRANSFER`.
- Real MinePage unknown state exposes “重新检查”; its probe reruns and the row shows
  “检查中…” during detection. Widget tests cover unknown → checking → result.

## 4. Repeat save and selection

New saved indices advance the post save time. A repeat association without a new
file preserves it. Soft-delete restoration keeps its existing explicit user-save
semantics. Tests cover both new-file and no-op cases. Both selection implementations
only edit the current selection when an existing item is unchecked; no delete call
or deletion prompt is added. Individual post-item deletion remains a v1.11 task.

## 5. Fullscreen image loading

App remote still/Live viewers keep their thumbnail beneath the original and show
a loading indicator. Original local images use their own AssetEntity thumbnail
until the original's first decoded frame. The native overlay paints the selected
cell's cached thumbnail bitmap with FIT_CENTER before loading the original; missing
thumbnails retain the prior loading state. The added Robolectric test mounts,
measures and draws the real SelectPanelView with a cached portrait thumbnail,
checks that bitmap plus visible progress, and saves a PNG. APK verification checks
the actual Dart widget sources and the native loadImage cache/paint call sites.

## 6. X restricted content

Explicit authentication error codes/messages, NsfwLoggedOut and age-gated tombstones
return LOGIN_REQUIRED with “该内容需要登录 X 才能查看”. Empty syndication responses remain
unavailable because they contain no evidence distinguishing deletion/private/age
restrictions. The supplied X failure alone therefore cannot prove which category
that particular post will return after this change. New fixtures are additive;
existing fixtures and provenance sources are unchanged. WebView X login, with
cookies retained only there, is recorded in v1.11.md and is not implemented here.

## Validation and release

Final local gates: Flutter **838/838** (`build28-flutter-final-approved.log`),
Android **101/101**, 0 skipped (`build28-android-final.log`, 26 JUnit classes),
Vitest **215/215** and Node release checks **28/28**. TypeScript checking, extension
production build and unsigned release candidate build pass. Dart library analysis
exits 0 with no errors and 61 warning/info diagnostics; no suppression is added.
Earlier failed runs are retained
under app/build/build28-*.log and are not counted as passing gates. No skips,
threshold reductions, suppression comments, album deletion, uninstall, pm clear,
run-as or private signing key access are used.

APK: `app/build/app/outputs/flutter-apk/EasySave-1.10.0-build28-debug.apk`,
**202,077,654 bytes**, package `com.james.easysave`, **1.10.0+28**.
SHA-256: `4cca50a3bbf620a45224e3224c1ea5547df83e9ff81b587a456c95bca37486d7`.
`apksigner verify` passes; certificate SHA-256
`7ec6c14f1c8c9fff6de9a31fda73150c12db7c81c98ee8017960d838aecb3484`
matches build 27. `verify_build28_apk.py` passes: 17 embedded Dart sources match
the working sources byte-for-byte, native DEX loadImage reads the thumbnail bitmap
cache and paints it, and parser/manifest bytes and digest match the APK assets.
Parser SHA-256: `5b4dec3ee70b5330e242d75f7fcf1206f7aed33ad1f442a1851b803d29a24a7f`.
APK evidence is under `app/build/v1411/`; actual native render PNG is
`app/android/app/build/reports/build28-preview/thumbnail-loading.png`.
The initial APK verification correctly rejected an older APK while assembleDebug
was still running; only the final completed and verified artifact above is delivered.

Release CI and independent published-byte verification are appended after release.

## Device retest steps

1. Cover-install build 28 without clearing data. Confirm 1.10.0+28 and parser
   1.4.11 / 7, check cloud update and restart persistence. Both APK and parser are
   required; the APK includes the parser for the initial offline state.
2. Reopen the three reported XHS posts from App and overlay. On the 9-image post,
   download exactly 3 indices; compare the card, actual saved viewer indices,
   deletion confirmation and album. Do not approve deletion merely to test counts.
   On the 8-image post, check each “本地已有” thumbnail against its original index.
   Revisit old failed single-image history after successful saving; its state must
   be success. Refresh/restart and repeat counts to check durable cleanup.
3. Download another new index of an already saved post; it must move to the top
   of latest-save sorting. Repeat with only existing indices; save time must remain.
   Uncheck an existing index and confirm no deletion prompt or album deletion.
4. Keep overlay downloads active, enter/refresh history repeatedly, and switch tabs
   while the phone is busy. A transient read failure must retain prior content and
   recover automatically; an empty-page retry must really read again. Export logs
   after this test and inspect HistoryDb/HistoryTiming plus removedPlaceholders.
5. On mobile data, let overlay parse/cache the 8-image short link, then retry the
   same App failure. It should hit cache; explicit reparse remains a cache bypass.
   Inspect immediate per-item preparing/downloading states and failure categories.
   If parsing still times out, export XhsDomain and ParseWebView stage/path/domain.
6. In Mine, trigger an unknown login check under poor network; use “重新检查” after
   connectivity returns and verify visible checking state and final status.
7. Open App and overlay full images on slow network: own thumbnail appears at the
   correct aspect ratio with a spinner, then original replaces it. Cover image and
   Live still paths are included. Regress IG AI labels and IG/X/TikTok downloads.
8. Retry the reported restricted X link without X login. If the service returns
   explicit login/age evidence, expect the new login wording; a blank public API
   response is still ambiguous. No X login screen should be introduced.
