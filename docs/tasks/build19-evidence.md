# Build 19 corrective handoff

This handoff supersedes the incomplete build 19 handoff at `9531fc3`. Scope is the build 18 device feedback A1/A2/B/C/D; the v1.11 deletion and loopback-preview candidates are not implemented here.

## A1: Mainland login and cookie-free redirect evidence

Command, run from the repository root on 2026-11-04:

```powershell
$env:CLAUDE_CONFIG_DIR = "$PWD/.claude"
rtk proxy python tools/probe_xhs_redirects.py
```

The script opens fresh HTTPS connections without a cookie jar, Cookie request header, or cookie access. It reads only the response status and Location; it does not read response bodies or Cookie/Set-Cookie headers. Redirect requests follow Location without recording query parameters. The desktop UA matches the X11 Chrome 141 UA in `config/sites.json`; mobile uses Android Chrome 141 Mobile. TLS verification remains enabled.

| UA | Accept-Language | First status | Location domain | Location path category | Next status |
| --- | --- | --- | --- | --- | --- |
| desktop | zh-CN | 302 | www.xiaohongshu.com | login | 200 |
| desktop | en | 302 | www.xiaohongshu.com | login | 200 |
| desktop | fr | 302 | www.xiaohongshu.com | login | 200 |
| mobile | zh-CN | 302 | www.xiaohongshu.com | root | 200 |
| mobile | en | 302 | www.xiaohongshu.com | root | 200 |
| mobile | fr | 302 | www.xiaohongshu.com | root | 200 |

This establishes a UA-dependent HTTP landing category on this computer/network, and no language-dependent HTTP cross-domain redirect in these six cases. It does **not** reproduce or establish the complete trigger for the device's rednote redirect. HTTP requests do not execute JavaScript; network/region, browser-side navigation, and existing device state remain unconfirmed variables. The supplied device logs remain authoritative: the mainland entry did land at rednote/login, and guest web_session is not authentication. Do not describe the desktop matrix as proof of device resolution.

Reference reviewed read-only: `refs/xhs/app/src/main/java/com/neoruaa/xhsdn/data/account/WebAccountRepository.kt`, `XhsWebSession.desktopUserAgent`, and the upstream [NEORUAA repository](https://github.com/NEORUAA/XHS_Downloader_Android). The reference converts browser identification to desktop and removes Mobile/Version markers. No reference implementation was copied. Build 18's builtin config already contained a desktop UA, so changing a UA string alone would not explain its device behavior.

Implementation:

- `config/sites.json`: mainland `auth.loginUrl` now opens `/login` directly; session probes remain `/explore`. Both login and parsing use the same configured desktop UA.
- `LoginPage`: explicitly selects desktop content mode, wide viewport, overview and zoom. On a trusted mainland page, a bounded observer selects the site's visible QR-login tab when offered; it does not submit credentials or manufacture login state. The actual WebView page displays: `扫码登录：截屏后用小红书 App 的“扫一扫 → 从相册选择”完成登录。`
- Login completion/polling requires `readAccount(...).loggedIn == true` on the requested origin. Missing page-state support now fails closed for XHS, even with a synthetic visitor web_session. Cookies alone cannot satisfy this path.

The login WebView, parsing headless WebView, and session probes use Android's default shared `android.webkit.CookieManager` store, including across the foreground and HostService Flutter engines in the same app process. Cookies remain domain/path scoped: sharing the store does not copy xiaohongshu cookies to rednote or share Chrome's store. UA is not part of CookieManager's storage key, so desktop UA is not intrinsically required to retrieve the same stored cookie. A site can still treat differing UAs differently; this build keeps login, probes and parsing on the same desktop UA for consistency. Actual session survival must be confirmed by page state on the device.

## A2: Actual widgets and why build 18 copy was invisible

`EasySaveApp -> MainShell -> MinePage` renders the 我的 tab. `MinePage._openLogin` had its own `SimpleDialog` containing `小红书登录` / `Rednote 登录`. It passed `entryUrl` directly to `LoginPage`, bypassing LoginPage's generic selector. Build 18 changed only the generic selector's account labels, so the real account-tab popup continued to display the old text. The WebView/login banner itself is rendered by `LoginPage`, not by a native dialog.

Both selectors now render `XhsLoginChoices`, using `小红书（中国大陆账号）` and `rednote（海外账号）`. The mainland login route has a local QR guide even if an older signed active manifest supplies older general help text. Signed parser activation, signature checks and anti-rollback rules are unchanged; an older active parser config can still supply its own UA, and APK builtin evidence alone does not establish which remote configuration a device has activated.

Widget regressions:

- `app/test/mine_login_widget_test.dart`: mounts the real MinePage, taps its XHS login button, and checks its real SimpleDialog labels and scan instructions; also checks both rendered choices' destination URLs.
- `app/test/login_site_selection_test.dart`: mounts the real LoginPage, chooses mainland login and captures WebView creation parameters (desktop UA/content mode, shared cookies, `/login`) plus the rendered QR guide; retains the generic two-domain chooser regression.
- `app/test/xhs_cookie_state_test.dart`: supplies a synthetic guest web_session and verifies that missing page-state support cannot authenticate XHS.
- `tools/xhs_qr_login.test.cjs`: executes the actual injected JavaScript against synthetic DOMs, checking visible and late QR tabs, hidden tabs and foreign/misleading domains.

Compiled APK inspection command (from repository root):

```powershell
$env:PYTHONIOENCODING = 'utf-8'
rtk proxy python tools/verify_build19_apk.py app/build/app/outputs/flutter-apk/app-debug.apk --dexdump D:/Android/Sdk/build-tools/35.0.1/dexdump.exe
```

The verifier searches `assets/flutter_assets/kernel_blob.bin` for UTF-8 UI strings, rather than treating source files or an unused asset as proof. It separately checks the APK's builtin site config and disassembles its DEX code. Final output and artifact identity are recorded below after the final build.

## B: One append implementation and complete records

Two separate problems were present: native code wrote `files/app_flutter/v16dl.log`, while `path_provider_android.getApplicationSupportPath` resolves to `files/`; and Dart/native append operations were not protected by a common in-process mutex. Matching lock filenames alone did not establish a shared sink or cross-runtime exclusion. The old native FileChannel single-write call also did not guarantee completion of a partial write.

Android Dart logging now calls `easysave/dev_log` method `append`; both MainActivity and HostService register this channel before their Dart logging uses it. Native PreviewPlayer and other native tags use the same `NativeLogFileWriter(files/v16dl.log)`. Its process-wide ReentrantLock plus file lock covers seek-to-end, complete byte-array write, flush and rotation. Export and clear use the same lock. Embedded CR/LF is escaped so one diagnostic remains one physical line. Android Dart no longer independently opens the log file. Existing historical fragments cannot be reconstructed; clear the diagnostic log and restart the app before collecting a fresh retest.

Tests:

- `app/test/dev_log_channel_test.dart`: 120 foreground/background/preview Dart calls all route complete lines through the native channel; redaction, export and clear use that channel.
- `app/android/app/src/test/kotlin/com/james/easysave/NativeLogFileWriterTest.kt`: 200 concurrent mixed-source appends preserve every distinct complete UTF-8 record, propagate worker exceptions, escape embedded newlines, and verify rotation/export/clear against the same sink.

The APK verifier requires actual DEX invocation instructions from **both** MainActivity and HostService to `NativeLog.register`, the `easysave/dev_log` MethodChannel handler, and the common file writer's append call. It also verifies the cached local-file MediaPlayer overload. A string-table match alone is not accepted as channel-connection evidence.

Expected first native marker after a fresh app start (export DevLog after restarting, without clearing it again):

```text
[INFO] [NativeLog] event=ready sink=files/v16dl.log transport=easysave/dev_log
```

Opening overlay video preview should subsequently produce, for example:

```text
[INFO] [PreviewPlayer] event=prepare host=video.twimg.com errorCode=none headers=referer
```

The host/header-name set depends on the selected resource. No media URL query or cookie value belongs in these records.

## C: Overlay video rollback

Restored the project's build 17 `playVideo` implementation: policy-checked download to a private temporary MP4, then MediaPlayer `setDataSource(file.absolutePath)`. This removes build 18's unknown-size, per-read HTTPS MediaDataSource from the active preview path. HTTPS/host/header/redirect validation and cookie-required-resource handoff remain in place. Temporary files are deleted when preview is closed or superseded; stale-generation completions are ignored. Posters, aspect-ratio handling, Live still fallback and first-frame timeout retain the existing behavior. No loopback server is introduced. Device playback remains a retest item; static APK evidence does not prove IG/X codec or network success.

## D: Test-count correction

The build 18 handoff copied build 17's `661` total incorrectly. Build 18 added two tests in `app/test/login_manifest_test.dart`: `four XHS domain combinations select the valid origin for both origins` and `rednote h5_feed load keeps post path and auth query shape`; it modified, rather than added, the existing selector test in `app/test/login_site_selection_test.dart`. Those changes imply 663 tests, not an unchanged 661. The two C1 tests claimed in that handoff were only added later to `app/test/gallery_locator_service_test.dart` in `d200f1b`: `deleted history records are not reported as downloaded` and `a missing MediaStore asset is not reported as present`, producing the earlier build 19 baseline of 665. This handoff distinguishes the incorrect historical count from the final test runner's observed count below.

## Final gates and artifact

- Flutter final full suite: **671 passed**, `rtk proxy flutter test --no-pub --reporter expanded`; raw output `app/build/build19-flutter-test-final.log`. This is the earlier 665 baseline plus two MinePage/choice tests, two log-channel tests, one actual login-WebView widget test, and one guest-session test.
- Android: **73 passed, 0 failures, 0 errors**, across 19 JUnit XML files; `rtk proxy .\gradlew.bat :app:testDebugUnitTest --console=plain`. Includes all three NativeLogFileWriter tests. Raw output `app/build/build19-android-test.log`; XML under `app/build/app/test-results/testDebugUnitTest/`.
- Extension: **159 Vitest + 21 build checks passed**, with typecheck, via `rtk proxy npm test`; production `rtk proxy npm run build` also passed. Raw outputs `app/build/build19-extension-test.log` and `app/build/build19-extension-build.log`.
- QR DOM regressions: **4 passed**, `rtk proxy node --test tools/xhs_qr_login.test.cjs`.
- The first guest-session regression run failed during test cleanup because the platform interface rejects assigning null; cleanup was corrected, the focused tests passed, and the final full suite above passed. No implementation commit was made with a failing gate.
- `rtk proxy flutter analyze --no-pub --no-fatal-infos --no-fatal-warnings`: exit **0**, no errors, 75 warning/info diagnostics; raw output `app/build/build19-analyze.log`.
- Final APK inspection and implementation/artifact commit identities follow after the build.
