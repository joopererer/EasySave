# Device Test Run Plan (v1.7)

## Overview
Real device automated test for EasySave App. Tests metadata writing, deletion behavior, and history recovery.
- **Device**: ead4148c (Xiaomi M2002J9E, connected via adb)
- **Output**: D:\temp\easysave-device-test\<timestamp>\
- **Test URLs**: From spec/fixtures/sources.json (XHS multi-image, Instagram carousel, X multi-photo)

## Mandatory Safety Rules
- ❌ Never: `adb uninstall`, `pm clear`, app data deletion
- ❌ Never: Delete `/sdcard` files or album files
- ❌ Never: Read app private dir (`app_webview/`, `cookie/`, `run-as`)
- ❌ Never: Delete history records not created by this test
- 🔹 If unsure about a destructive operation: STOP and ask

## Test Setup
1. ✅ Extension tests pass: `npm test` (already verified)
2. App installed and fresh for test
3. Device has real album data (protected)

## Test Cases

### a. Metadata Write & Validation
**Goal**: Verify XMP metadata compliance after download via ShareToBackgroundActivity

**Steps**:
1. Extract test URLs from spec/fixtures/sources.json:
   - XHS: `xhs_multi` (multi-image post)
   - Instagram: `ig_carousel` (carousel)
   - X: `multi_photo` (multi-photo tweet)

2. Share each URL via background activity:
   ```
   adb shell am start -W \
     -a android.intent.action.SEND \
     -t "text/plain" \
     -e android.intent.extra.TEXT "<URL>" \
     com.james.easysave/.ShareToBackgroundActivity
   ```

3. Wait for completion (monitor logcat for completion markers)

4. Pull downloaded files to D:\temp\easysave-device-test\<timestamp>\<platform>\

5. For each file, run exiftool to verify:
   - `Platform` (xhs/instagram/x)
   - `SourceUrl` (normalized post URL, matching spec)
   - `ItemIndex` (1-based, matches filename position)
   - `ItemCount` (total items in post)
   - `AuthorId` (present for XHS/IG, empty for X)
   - `CapturedAt` (ISO 8601 with timezone)

**Expected**:
- All files have correct XMP metadata
- No exiftool read errors
- ItemIndex starts at 1, sequential per post

---

### b. Deletion Does Not Resurrect
**Goal**: Verify deleted records stay deleted after app restart

**Steps**:
1. In History page: long-press one newly-downloaded record from (a)
2. Tap delete button → show deletion sheet
3. Uncheck "删除相册文件" (only delete record, not file)
4. Tap "删除"
5. Verify record disappears from History
6. Force-stop and restart app 3 times:
   ```
   adb shell am force-stop com.james.easysave
   adb shell am start -W -n com.james.easysave/.MainActivity
   <navigate to History>
   ```
7. Verify deleted record does NOT reappear after each restart

**Expected**:
- Record deleted and stays deleted
- App does not resurrect it on restart

---

### c. User Re-download Restores Deleted Record
**Goal**: Verify re-downloading a deleted post restores it to History

**Steps**:
1. Share the same URL from (a) again via ShareToBackgroundActivity
2. Wait for completion
3. Navigate to History page
4. Verify the previously-deleted record reappears

**Expected**:
- Record restored to History with same ItemIndex/ItemCount/metadata

---

### d. Rebuild History Does Not Create Duplicates
**Goal**: Verify rebuild from album does not duplicate existing records

**Steps**:
1. Delete another test record (record-only, not file)
2. Go to Settings → "从相册重建历史"
3. Wait for rebuild to complete (monitor Toast/logs)
4. Navigate to History
5. Verify deleted record reappears
6. Verify no duplicates in History

**Expected**:
- Deleted record restored
- No duplicate entries
- History count consistent

---

### e. Backfill Source Info & Verify Zero Re-write
**Goal**: Verify source info backfill for v1.7 files and no re-write on second run

**Steps**:
1. Go to Settings → "为旧文件补写来源信息"
2. Wait for completion (monitor Toast/logs and capture statistics)
3. Capture backfill statistics (e.g., "Wrote source info to 2 files")
4. Pick 2 pre-v1.7 album files, pull them:
   ```
   adb shell find /sdcard/DCIM -name "*.jpg" -type f | head -20
   adb pull <path-to-file> D:\temp\easysave-device-test\<timestamp>\backfill\
   ```
5. Verify with exiftool:
   - File has `XMP-prov` namespace with source fields
   - `CapturedAt` equals original download date (from file metadata)
6. Run backfill again
7. Verify Toast shows "0 files" written (idempotent)

**Expected**:
- Backfill writes source info to old files
- CapturedAt preserved as download date
- Re-run is idempotent (0 writes)

---

## UI Automation Reference
- Locate controls: `adb shell uiautomator dump /sdcard/ui-dump.xml`
- Tap button: `adb shell input tap <x> <y>`
- Type text: `adb shell input text "<text>"`
- Screenshot: `adb exec-out screencap -p > output.png`

## Not Automated (Manual)
- Loading spinners during parse
- Download progress notif
- Floating bubble appearance
- Select-download multi-choice UI
- System permission dialogs

## Output Report
After all tests pass, generate `docs/tasks/v1.7-device-test.md`:
- [ ] a. Metadata write: PASS/FAIL + exiftool sample output
- [ ] b. Deletion stays deleted: PASS/FAIL + screenshots
- [ ] c. Re-download restores: PASS/FAIL + History screenshot
- [ ] d. Rebuild no duplicates: PASS/FAIL + History count
- [ ] e. Backfill idempotent: PASS/FAIL + statistics + sample exiftool

## Logcat Markers (for monitoring)
- Download start: `V16SHARE`
- Download complete: `HostService` + `Idle timeout` or `completed` message
- Rebuild complete: Look for Toast message in logcat
- Backfill complete: Look for Toast message in logcat
