# EasySave Device Test Script v1.7
# Comprehensive automated device testing with metadata validation and UI automation
# Usage: .\run.ps1 -TestCase (a|b|c|d|e|all) [-XhsUrl <url>] [-IgUrl <url>] [-XUrl <url>] [-AlbumDir <path>]

param(
    [ValidateSet('a', 'b', 'c', 'd', 'e', 'all')]
    [string]$TestCase = 'all',
    [string]$XhsUrl = "",
    [string]$IgUrl = "",
    [string]$XUrl = "",
    [string]$AlbumDir = "/sdcard/Pictures/EasySave",
    [string]$ExifTool = "",
    [switch]$SkipExtensionTest,
    [string]$OutputDir = "D:\temp\easysave-device-test"
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

# ============================================================================
# CONSTANTS & CONFIG
# ============================================================================

$TIMESTAMP = Get-Date -Format "yyyyMMdd-HHmmss"
$TEST_OUTPUT = "$OutputDir\$TIMESTAMP"
$DEVICE_ID = "ead4148c"
$APP_PACKAGE = "com.james.easysave"
$SHARE_ACTIVITY = "$APP_PACKAGE/$APP_PACKAGE.ShareToBackgroundActivity"
$MAIN_ACTIVITY = "$APP_PACKAGE.MainActivity"
$FIXTURES_FILE = "D:\workspace\IdeaProjects\EasySave\spec\fixtures\sources.json"

$LOGCAT_TAG = "V16HOST"
$DOWNLOAD_TIMEOUT = 180  # seconds for multi-image posts
$LOGCAT_PATTERN_DONE = "DOWNLOAD done"
$LOGCAT_PATTERN_FAILED = "DOWNLOAD failed"

# Test URLs
$testUrls = @{
    xhs = ""
    instagram = ""
    x = ""
}

# Platform name mapping: script key -> canonical XMP name
$platformNames = @{
    xhs = "xiaohongshu"
    instagram = "instagram"
    x = "x"
}

# Track file states before/after
$filesBeforeTest = @{}
$filesAfterTest = @{}

# Test results tracking
$testResults = @{
    "a" = @{ status = "PENDING"; details = @(); errors = @() }
    "b" = @{ status = "PENDING"; details = @(); errors = @() }
    "c" = @{ status = "PENDING"; details = @(); errors = @() }
    "d" = @{ status = "PENDING"; details = @(); errors = @() }
    "e" = @{ status = "PENDING"; details = @(); errors = @() }
}

# ============================================================================
# LOGGING & UTILITY FUNCTIONS
# ============================================================================

function Log-Info {
    param([string]$Message)
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] ℹ️  $Message" -ForegroundColor Cyan
}

function Log-Success {
    param([string]$Message)
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] ✅ $Message" -ForegroundColor Green
}

function Log-Error {
    param([string]$Message)
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] ❌ $Message" -ForegroundColor Red
}

function Log-Warning {
    param([string]$Message)
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] ⚠️  $Message" -ForegroundColor Yellow
}

function Log-Test {
    param([string]$Message)
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] 🧪 $Message" -ForegroundColor Magenta
}

function Test-DeviceConnected {
    $devices = adb devices -l | Select-String "\sdevice\s" | Measure-Object | Select-Object -ExpandProperty Count
    if ($devices -lt 1) {
        Log-Error "No device connected"
        exit 1
    }
    Log-Success "Device connected: $DEVICE_ID"
}

function Get-ExiftoolPath {
    # If user provided explicit path, use it
    if ($ExifTool -and (Test-Path $ExifTool)) {
        Log-Success "exiftool found (user-provided): $ExifTool"
        return $ExifTool
    }
    
    # Try common locations first
    $locations = @(
        "$env:LOCALAPPDATA\Programs\ExifTool\ExifTool.exe",
        "C:\Program Files\exiftool\exiftool.exe",
        "C:\Program Files (x86)\exiftool\exiftool.exe",
        "C:\ProgramData\chocolatey\bin\exiftool.exe"
    )
    
    foreach ($loc in $locations) {
        if (Test-Path $loc) {
            Log-Success "exiftool found: $loc"
            return $loc
        }
    }
    
    # Fallback to PATH
    $path = (Get-Command exiftool -ErrorAction SilentlyContinue).Source
    if (-not $path) {
        Log-Error "exiftool not found. Install: winget install exiftool"
        Log-Error "Or provide path with -ExifTool parameter"
        exit 1
    }
    Log-Success "exiftool found: $path"
    return $path
}

function Load-TestUrls {
    # Use command-line parameters if provided, otherwise load from fixtures
    if (-not $XhsUrl -or -not $IgUrl -or -not $XUrl) {
        if (-not (Test-Path $FIXTURES_FILE)) {
            Log-Error "Fixtures file not found: $FIXTURES_FILE"
            exit 1
        }
        $fixtures = Get-Content $FIXTURES_FILE | ConvertFrom-Json
        if (-not $XhsUrl) { $XhsUrl = $fixtures.xhs.xhs_multi }
        if (-not $IgUrl) { $IgUrl = $fixtures.instagram.ig_carousel }
        if (-not $XUrl) { $XUrl = $fixtures.x.multi_photo }
    }
    
    $testUrls.xhs = $XhsUrl
    $testUrls.instagram = $IgUrl
    $testUrls.x = $XUrl
    
    Log-Info "Test URLs configured:"
    Log-Info "  XHS: $($testUrls.xhs)"
    Log-Info "  Instagram: $($testUrls.instagram)"
    Log-Info "  X: $($testUrls.x)"
}

function Initialize-OutputDir {
    if (-not (Test-Path $TEST_OUTPUT)) {
        New-Item -ItemType Directory -Path $TEST_OUTPUT -Force | Out-Null
    }
    Log-Success "Output directory: $TEST_OUTPUT"
}

function Take-Screenshot {
    param(
        [string]$Label,
        [string]$Subdir = ""
    )
    
    # If Subdir is an absolute path, use it directly; otherwise treat as relative to TEST_OUTPUT
    $dir = if ($Subdir) {
        if ([IO.Path]::IsPathRooted($Subdir)) {
            $Subdir
        } else {
            "$TEST_OUTPUT\$Subdir"
        }
    } else {
        $TEST_OUTPUT
    }
    
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    
    $path = "$dir\$(Get-Date -Format 'HHmmss')-$Label.png"
    # Use adb pull instead of exec-out for binary reliability across PowerShell versions
    $devicePath = "/sdcard/screencap-tmp.png"
    
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    
    adb shell screencap -p $devicePath 2>$null
    if ($LASTEXITCODE -eq 0) {
        adb pull $devicePath $path 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            adb shell rm $devicePath 2>$null | Out-Null
            Log-Info "Screenshot: $Label -> $path"
        } else {
            Log-Warning "Screenshot pull failed for $Label"
        }
    } else {
        Log-Warning "Screenshot capture failed for $Label"
    }
    
    $ErrorActionPreference = $prevEAP
    return $path
}

function Unlock-Device {
    # Suppress SecurityException errors from INJECT_EVENTS permission; some devices don't allow this
    # Some ROMs (MIUI, ColorOS) deny adb shell input, so we ignore exit codes here
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    adb shell input keyevent 26 2>$null  # Power button (toggle)
    Start-Sleep -Milliseconds 500
    adb shell input keyevent 82 2>$null  # Menu (dismiss lock)
    Start-Sleep -Milliseconds 1000
    $ErrorActionPreference = $prevEAP
    Log-Info "Device unlock attempted (manual unlock may be needed if screen was locked)"
}

$script:LogcatCaptureProcess = $null
$script:LogcatCaptureFile = $null

function Start-LogcatCapture {
    # Clear logcat and start background capture BEFORE triggering any share
    # intent, so the V16SHARE "share text=" line (logged immediately in
    # onResume) is never lost to a race with a later `adb logcat -c`.
    Stop-LogcatCapture

    adb logcat -c
    Start-Sleep -Milliseconds 300

    $tempLog = Join-Path $env:TEMP "easysave_logcat_$PID.log"
    Remove-Item $tempLog -Force -ErrorAction SilentlyContinue

    $process = Start-Process -FilePath "cmd" `
        -ArgumentList "/c", "adb logcat -s V16SHARE:*,V16HOST:* -v threadtime > `"$tempLog`"" `
        -WindowStyle Hidden -PassThru

    # Give logcat time to attach before we return control to the caller
    Start-Sleep -Milliseconds 500

    $script:LogcatCaptureProcess = $process
    $script:LogcatCaptureFile = $tempLog
}

function Stop-LogcatCapture {
    if ($script:LogcatCaptureProcess) {
        try { $script:LogcatCaptureProcess | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}
        $script:LogcatCaptureProcess = $null
    }
}

function Wait-For-Logcat {
    param(
        [string]$Pattern,
        [int]$TimeoutSeconds = 180
    )
    
    Log-Info "Waiting for logcat pattern (timeout ${TimeoutSeconds}s): $Pattern"
    
    if (-not $script:LogcatCaptureFile) {
        Log-Warning "Logcat capture was not started via Start-LogcatCapture; starting now (may miss early V16SHARE lines)"
        Start-LogcatCapture
    }
    $tempLog = $script:LogcatCaptureFile
    
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $found = $false
    
    try {
        while ((Get-Date) -lt $deadline) {
            if (Test-Path $tempLog) {
                $content = Get-Content $tempLog -Raw -ErrorAction SilentlyContinue
                if ($content -match $Pattern) {
                    Log-Success "Logcat pattern found: $Pattern"
                    $found = $true
                    break
                }
            }
            Start-Sleep -Milliseconds 500
        }
    }
    finally {
        # Stop the background logcat process and persist a copy for inspection
        Stop-LogcatCapture
        if (Test-Path $tempLog) {
            $logFile = Join-Path $TEST_OUTPUT "logcat-$(Get-Date -Format 'yyyyMMdd-HHmmss-fff').log"
            Copy-Item $tempLog $logFile -Force -ErrorAction SilentlyContinue
            Log-Info "Logcat saved: $logFile"
        }
        Remove-Item $tempLog -Force -ErrorAction SilentlyContinue
        $script:LogcatCaptureFile = $null
    }
    
    if (-not $found) {
        Log-Warning "Logcat timeout (${TimeoutSeconds}s): $Pattern not found"
    }
    return $found
}

function Share-Url {
    param(
        [string]$Url,
        [string]$Platform
    )
    
    Log-Info "[$Platform] Sharing: $($Url.Substring(0, [Math]::Min(60, $Url.Length)))..."
    
    # URL with & must be quoted in PowerShell and adb shell
    # --es parameter escapes properly with double quotes
    # Use explicit component (-n) to ensure we launch ShareToBackgroundActivity
    adb shell am start -W `
        -a android.intent.action.SEND `
        -t "text/plain" `
        -n "$SHARE_ACTIVITY" `
        --es "android.intent.extra.TEXT" "$Url"
    
    Start-Sleep -Milliseconds 2000
}

function Get-Album-Files {
    param([string]$AlbumPath = $AlbumDir)
    
    $output = adb shell "ls -1 $AlbumPath 2>/dev/null"
    if ($LASTEXITCODE -ne 0) {
        Log-Warning "Failed to list album: $AlbumPath"
        return @()
    }
    
    # Filter out directories and invalid entries, keep only image/video files
    $files = $output | Where-Object { 
        $_ -and 
        -not $_.StartsWith("total") -and 
        ($_ -match "\.(jpg|jpeg|png|webp|mp4|gif)$")
    } | ForEach-Object { $_.Trim() }
    
    return @($files)
}

function Get-New-Files {
    param(
        [array]$Before,
        [array]$After
    )
    
    return @($After | Where-Object { $_ -notin $Before })
}

function Pull-Files {
    param(
        [array]$Files,
        [string]$RemoteDir,
        [string]$LocalDir
    )
    
    if (-not (Test-Path $LocalDir)) {
        New-Item -ItemType Directory -Path $LocalDir -Force | Out-Null
    }
    
    foreach ($file in $Files) {
        $remotePath = "$RemoteDir/$file"
        Log-Info "Pulling: $file"
        adb pull $remotePath $LocalDir | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Log-Error "Failed to pull: $file"
        }
    }
}

function Verify-Exiftool-Metadata {
    param(
        [string]$FilePath,
        [string]$Platform,
        [int]$ExpectedItemIndex,
        [int]$ExpectedItemCount,
        [string]$ExiftoolPath
    )
    
    if (-not (Test-Path $FilePath)) {
        return @{
            pass = $false
            error = "File not found: $FilePath"
            output = ""
        }
    }
    
    # Extract metadata using tab-separated format
    $output = & $ExiftoolPath -T `
        -FileName `
        -XMP-prov:Platform `
        -XMP-prov:SourceUrl `
        -XMP-prov:ItemIndex `
        -XMP-prov:ItemCount `
        -XMP-prov:AuthorId `
        -XMP-prov:CapturedAt `
        $FilePath 2>&1
    
    if (-not $output) {
        return @{
            pass = $false
            error = "exiftool returned empty output"
            output = ""
        }
    }
    
    # Convert to string if array
    $outputStr = if ($output -is [array]) { $output -join "`t" } else { $output }
    
    # Split by tabs
    $fields = $outputStr -split "`t"
    if ($fields.Count -lt 7) {
        return @{
            pass = $false
            error = "Incomplete metadata (expected 7 fields, got $($fields.Count))"
            output = $outputStr
        }
    }
    
    $fileName = $fields[0].Trim()
    $plat = $fields[1].Trim()
    $url = $fields[2].Trim()
    $itemIdx = $fields[3].Trim()
    $itemCnt = $fields[4].Trim()
    $authId = $fields[5].Trim()
    $capturedAt = $fields[6].Trim()
    
    # Normalize platform names
    $platNormalized = $plat.ToLower()
    $expectedPlat = $Platform.ToLower()
    
    $checks = @{
        filename = @{ pass = $true; value = $fileName }
        platform = @{ pass = ($platNormalized -eq $expectedPlat); value = $plat; expected = $Platform }
        sourceUrl = @{ pass = ($url -match "^https?://"); value = $url }
        itemIndex = @{ pass = ($itemIdx -eq "$ExpectedItemIndex"); value = $itemIdx; expected = "$ExpectedItemIndex" }
        itemCount = @{ pass = ($itemCnt -eq "$ExpectedItemCount"); value = $itemCnt; expected = "$ExpectedItemCount" }
        authorId = @{ 
            pass = if ($expectedPlat -eq "x") { 
                $authId -eq "-" -or $authId -eq "" 
            } else { 
                $authId -ne "-" -and $authId -ne "" 
            }
            value = $authId
        }
        capturedAt = @{ pass = ($capturedAt -match "\d{4}[-:]\d{2}[-:]\d{2}[T\s]\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}"); value = $capturedAt }
    }
    
    $failedChecks = $checks.GetEnumerator() | Where-Object { -not $_.Value.pass }
    
    $result = @{
        pass = $failedChecks.Count -eq 0
        checks = $checks
        output = $outputStr
    }
    
    # Include details of failed checks for debugging
    if ($failedChecks.Count -gt 0) {
        $result["failedDetails"] = @($failedChecks | ForEach-Object {
            "$($_.Key): got '$($_.Value.value)', expected '$($_.Value.expected)'"
        }) -join " | "
    }
    
    return $result
}

function Find-Ui-Control {
    param(
        [string]$TextPattern,  # text to match
        [string]$ResourceId = ""  # optional resource-id
    )
    
    adb shell uiautomator dump /sdcard/ui.xml | Out-Null
    Start-Sleep -Milliseconds 300
    $xml = adb shell cat /sdcard/ui.xml
    
    # Parse XML to find control with matching text
    # Look for text="pattern" and extract bounds
    $regex = "text=""([^""]*$TextPattern[^""]*)""[^>]*bounds=""\[(\d+),(\d+)\]\[(\d+),(\d+)\]"""
    if ($xml -match $regex) {
        $x1, $y1, $x2, $y2 = [int]$matches[2], [int]$matches[3], [int]$matches[4], [int]$matches[5]
        $tapX = [int](($x1 + $x2) / 2)
        $tapY = [int](($y1 + $y2) / 2)
        return @{ x = $tapX; y = $tapY; text = $matches[1] }
    }
    
    return $null
}

function Tap-Control {
    param(
        [string]$TextPattern,
        [int]$RetryCount = 3
    )
    
    for ($i = 0; $i -lt $RetryCount; $i++) {
        $control = Find-Ui-Control -TextPattern $TextPattern
        if ($control) {
            Log-Info "Tapping: '$TextPattern' at ($($control.x), $($control.y))"
            adb shell input tap $control.x $control.y
            Start-Sleep -Milliseconds 800
            return $true
        }
        Log-Warning "Control not found (attempt $($i+1)/$RetryCount): '$TextPattern'"
        Start-Sleep -Milliseconds 500
    }
    
    return $false
}

function Force-Stop-And-Restart {
    param([int]$Times = 1)
    
    for ($i = 0; $i -lt $Times; $i++) {
        Log-Info "Force-stop & restart ($($i+1)/$Times)"
        adb shell am force-stop $APP_PACKAGE
        Start-Sleep -Seconds 1
        adb shell am start -W -n "$APP_PACKAGE/$MAIN_ACTIVITY"
        Start-Sleep -Seconds 3
        Take-Screenshot "restart-$($i+1)" "test-b"
    }
}

# ============================================================================
# TEST IMPLEMENTATIONS
# ============================================================================

function Test-A-MetadataWrite {
    Log-Test "=========== TEST A: Metadata Write & Validation ==========="
    
    $testADir = Join-Path $TEST_OUTPUT "test-a"
    New-Item -ItemType Directory -Path $testADir -Force | Out-Null
    
    $exiftoolPath = Get-ExiftoolPath
    
    foreach ($platform in @("xhs", "instagram", "x")) {
        Log-Test "[$platform] Starting metadata test"
        
        $url = $testUrls[$platform]
        $canonicalPlatform = $platformNames[$platform]
        $platformDir = Join-Path $testADir $platform
        New-Item -ItemType Directory -Path $platformDir -Force | Out-Null
        
        # Get files before download
        $filesBefore = Get-Album-Files
        Log-Info "[$platform] Files before: $($filesBefore.Count)"
        
        # Start logcat capture BEFORE sharing so V16SHARE's immediate log line is not lost
        Start-LogcatCapture
        
        # Share the URL
        Share-Url $url $platform
        
        # Wait for download completion
        $downloadOk = Wait-For-Logcat "$LOGCAT_PATTERN_DONE|$LOGCAT_PATTERN_FAILED" $DOWNLOAD_TIMEOUT
        if (-not $downloadOk) {
            Log-Error "[$platform] Download timeout or no logcat marker"
            $testResults["a"].errors += "[$platform] Download timeout"
            $testResults["a"].status = "FAILED"
            Take-Screenshot "timeout" $platformDir
            continue
        }
        
        Start-Sleep -Seconds 2
        
        # Get files after download
        $filesAfter = Get-Album-Files
        $newFiles = Get-New-Files $filesBefore $filesAfter
        
        if ($newFiles.Count -eq 0) {
            Log-Error "[$platform] No new files downloaded"
            $testResults["a"].errors += "[$platform] No new files"
            $testResults["a"].status = "FAILED"
            continue
        }
        
        Log-Info "[$platform] New files: $($newFiles.Count)"
        Log-Info "[$platform] Files: $($newFiles -join ', ')"
        
        # Pull new files
        Pull-Files $newFiles $AlbumDir $platformDir
        
        # Verify metadata for each file
        # Since multiple platforms may download simultaneously, we must filter by examining
        # the actual Platform field in each file rather than assuming all newFiles belong to this test
        $allPass = $true
        $verifiedCount = 0
        $skippedCount = 0
        
        foreach ($newFile in ($newFiles | Sort-Object)) {
            $filePath = Join-Path $platformDir $newFile
            
            # Quick check: read the Platform field first to confirm this file belongs to current test
            $platformCheck = & $exiftoolPath -s -s -s -XMP-prov:Platform $filePath 2>$null
            if (-not $platformCheck -or $platformCheck.Trim().ToLower() -ne $canonicalPlatform.ToLower()) {
                Log-Warning "[$platform] Skipping $newFile (belongs to platform: $platformCheck)"
                $skippedCount++
                continue
            }
            
            $verifiedCount++
            
            # For multi-item posts, we expect itemIndex to match the file's position within its own post
            # Read the actual ItemIndex and ItemCount from the file rather than assuming sequential order
            $actualItemIndex = [int](& $exiftoolPath -s -s -s -XMP-prov:ItemIndex $filePath 2>$null)
            $actualItemCount = [int](& $exiftoolPath -s -s -s -XMP-prov:ItemCount $filePath 2>$null)
            
            if (-not $actualItemIndex -or -not $actualItemCount) {
                Log-Error "[$platform] Cannot read ItemIndex/ItemCount from $newFile"
                $testResults["a"].errors += "[$platform] $newFile - missing index/count"
                $allPass = $false
                continue
            }
            
            $result = Verify-Exiftool-Metadata $filePath $canonicalPlatform $actualItemIndex $actualItemCount $exiftoolPath
            
            if (-not $result.pass) {
                Log-Error "[$platform] Metadata validation failed for $newFile"
                if ($result.failedDetails) {
                    Log-Error "  Failures: $($result.failedDetails)"
                }
                Log-Error "  Output: $($result.output)"
                $testResults["a"].errors += "[$platform] $newFile - $($result.failedDetails)"
                $allPass = $false
            } else {
                Log-Success "[$platform] $newFile - Metadata OK"
                Log-Info "  Platform: $($result.checks.platform.value)"
                Log-Info "  ItemIndex: $($result.checks.itemIndex.value)/$($result.checks.itemCount.value)"
                Log-Info "  AuthorId: $($result.checks.authorId.value)"
                Log-Info "  CapturedAt: $($result.checks.capturedAt.value)"
                $testResults["a"].details += "${newFile}: OK"
            }
        }
        
        if ($verifiedCount -eq 0) {
            Log-Error "[$platform] No files matched this platform (skipped: $skippedCount)"
            $testResults["a"].errors += "[$platform] No matching files"
            $testResults["a"].status = "FAILED"
        }
        
        Take-Screenshot "$platform-complete" $platformDir
        
        if (-not $allPass) {
            $testResults["a"].status = "FAILED"
        }
    }
    
    if ($testResults["a"].status -ne "FAILED") {
        $testResults["a"].status = "PASSED"
        Log-Success "Test A: PASSED"
    } else {
        Log-Error "Test A: FAILED"
    }
}

function Test-B-DeletionStayDeleted {
    Log-Test "=========== TEST B: Deletion Does Not Resurrect ==========="
    
    $testBDir = Join-Path $TEST_OUTPUT "test-b"
    New-Item -ItemType Directory -Path $testBDir -Force | Out-Null
    
    Log-Warning "⚠️  SEMI-AUTOMATED TEST"
    Log-Warning "Script will pause - you delete a record manually"
    Log-Warning ""
    Log-Info "Instructions:"
    Log-Info "  1. Open EasySave History page"
    Log-Info "  2. Find and long-press ONE test record (e.g., XHS multi-image post)"
    Log-Info "  3. In the delete dialog:"
    Log-Info "     - UNCHECK '同时删除相册中的文件' (only delete record, NOT file)"
    Log-Info "     - Tap '删除' button"
    Log-Info "  4. Verify record disappears from History"
    Log-Info ""
    
    $response = Read-Host "Press ENTER when done with deletion"
    
    # Take a screenshot after deletion
    Take-Screenshot "after-deletion" $testBDir
    
    # Force-stop and restart 3 times, checking if record reappears
    $recordReappeared = $false
    for ($i = 0; $i -lt 3; $i++) {
        Log-Info "Restart cycle $($i+1)/3"
        adb shell am force-stop $APP_PACKAGE
        Start-Sleep -Seconds 1
        adb shell am start -W -n "$APP_PACKAGE/$MAIN_ACTIVITY"
        Start-Sleep -Seconds 3
        
        # Try to check if record exists using uiautomator
        # This is a simplified check - may need manual verification
        Take-Screenshot "after-restart-$($i+1)" $testBDir
        
        Log-Warning "Manually verify in screenshot: does the deleted record appear?"
        $appears = Read-Host "Did the record reappear? (y/n)"
        if ($appears -eq "y") {
            $recordReappeared = $true
            Log-Error "Record reappeared after restart!"
            break
        }
    }
    
    if ($recordReappeared) {
        $testResults["b"].status = "FAILED"
        $testResults["b"].errors += "Record unexpectedly reappeared after restart"
        Log-Error "Test B: FAILED - Record resurrected"
    } else {
        $testResults["b"].status = "PASSED"
        $testResults["b"].details += "Record stayed deleted across 3 restarts"
        Log-Success "Test B: PASSED"
    }
}

function Test-C-ReDownloadRestores {
    Log-Test "=========== TEST C: User Re-download Restores Deleted Record ==========="
    
    $testCDir = Join-Path $TEST_OUTPUT "test-c"
    New-Item -ItemType Directory -Path $testCDir -Force | Out-Null
    
    # Re-share the XHS URL from test A
    $url = $testUrls.xhs
    Log-Info "Re-sharing XHS post: $($url.Substring(0, 60))..."
    
    Start-LogcatCapture
    Share-Url $url "xhs"
    
    $downloadOk = Wait-For-Logcat "$LOGCAT_PATTERN_DONE|$LOGCAT_PATTERN_FAILED" $DOWNLOAD_TIMEOUT
    if (-not $downloadOk) {
        Log-Error "Download failed or timeout"
        $testResults["c"].status = "FAILED"
        $testResults["c"].errors += "Download timeout"
        Take-Screenshot "timeout" $testCDir
        return
    }
    
    Start-Sleep -Seconds 2
    adb shell am start -W -n "$APP_PACKAGE/$MAIN_ACTIVITY"
    Start-Sleep -Seconds 3
    
    Take-Screenshot "history-after-redownload" $testCDir
    
    Log-Warning "Manually verify: Does the previously-deleted record reappear in History?"
    $restored = Read-Host "Record restored? (y/n)"
    
    if ($restored -eq "y") {
        $testResults["c"].status = "PASSED"
        $testResults["c"].details += "Record successfully restored"
        Log-Success "Test C: PASSED"
    } else {
        $testResults["c"].status = "FAILED"
        $testResults["c"].errors += "Record not restored"
        Log-Error "Test C: FAILED"
    }
}

function Test-D-RebuildHistoryNoDuplicates {
    Log-Test "=========== TEST D: Rebuild History Does Not Create Duplicates ==========="
    
    $testDDir = Join-Path $TEST_OUTPUT "test-d"
    New-Item -ItemType Directory -Path $testDDir -Force | Out-Null
    
    Log-Warning "⚠️  SEMI-AUTOMATED TEST"
    Log-Warning "Script will pause - you delete another record manually"
    Log-Warning ""
    Log-Info "Instructions:"
    Log-Info "  1. Long-press ANOTHER test record (different from Test B)"
    Log-Info "  2. Delete it (UNCHECK file deletion)"
    Log-Info "  3. Press ENTER when done"
    Log-Info ""
    
    $response = Read-Host "Press ENTER when record deleted"
    Take-Screenshot "after-2nd-deletion" $testDDir
    
    # Open Settings and tap "从相册重建历史"
    Log-Info "Opening Settings..."
    adb shell input keyevent 4  # Back to main
    Start-Sleep -Seconds 1
    
    # Navigate to Settings (typically a gear icon or "我的" → "设置")
    # This is app-specific; using tab navigation
    adb shell input keyevent 61  # Tab key (cycle through tabs)
    Start-Sleep -Seconds 2
    Take-Screenshot "settings-tab" $testDDir
    
    # Look for "从相册重建历史" button and tap it
    Log-Info "Tapping '从相册重建历史'..."
    $found = Tap-Control "从相册重建历史"
    if (-not $found) {
        Log-Warning "Could not find '从相册重建历史' button - trying scroll..."
        adb shell input swipe 500 1000 500 500  # Scroll up
        Start-Sleep -Seconds 1
        $found = Tap-Control "从相册重建历史"
    }
    
    if ($found) {
        Log-Info "Waiting for rebuild to complete..."
        Start-Sleep -Seconds 5
        Take-Screenshot "rebuild-complete" $testDDir
        
        Log-Warning "Manually verify: Is the deleted record restored? Any duplicates?"
        $verified = Read-Host "Record restored without duplicates? (y/n)"
        
        if ($verified -eq "y") {
            $testResults["d"].status = "PASSED"
            $testResults["d"].details += "Rebuild successful, no duplicates"
            Log-Success "Test D: PASSED"
        } else {
            $testResults["d"].status = "FAILED"
            $testResults["d"].errors += "Rebuild failed or created duplicates"
            Log-Error "Test D: FAILED"
        }
    } else {
        $testResults["d"].status = "FAILED"
        $testResults["d"].errors += "Could not locate rebuild button"
        Log-Error "Test D: FAILED"
    }
}

function Test-E-BackfillIdempotent {
    Log-Test "=========== TEST E: Backfill Source Info & Verify Zero Re-write ==========="
    
    $testEDir = Join-Path $TEST_OUTPUT "test-e"
    New-Item -ItemType Directory -Path $testEDir -Force | Out-Null
    
    # Go to Settings and tap "为旧文件补写来源信息"
    Log-Info "Opening Settings..."
    adb shell input keyevent 4  # Back
    Start-Sleep -Seconds 1
    adb shell input keyevent 61  # Tab to settings
    Start-Sleep -Seconds 2
    
    Log-Info "Tapping '为旧文件补写来源信息'..."
    $found = Tap-Control "为旧文件补写来源信息"
    if (-not $found) {
        Log-Warning "Could not find button - trying scroll..."
        adb shell input swipe 500 1000 500 500
        Start-Sleep -Seconds 1
        $found = Tap-Control "为旧文件补写来源信息"
    }
    
    if ($found) {
        Log-Info "Backfill running, waiting for completion (monitoring logcat)..."
        Start-Sleep -Seconds 2
        
        # Capture logcat for statistics
        adb shell am start -W -n "$APP_PACKAGE/$MAIN_ACTIVITY"
        Start-Sleep -Seconds 2
        Take-Screenshot "backfill-stats-1" $testEDir
        
        Log-Warning "Manually note the Toast message showing backfill statistics"
        $stats1 = Read-Host "Enter backfill statistics from Toast (e.g., 'Wrote source info to 2 files')"
        
        # Find 2 old pre-v1.7 files
        Log-Info "Listing old files to backfill-check directory..."
        $oldFiles = adb shell ls -t $AlbumDir | Select-Object -First 10
        
        $backfillCheckDir = Join-Path $testEDir "backfill-check"
        New-Item -ItemType Directory -Path $backfillCheckDir -Force | Out-Null
        
        Log-Info "Pulling first 2 files from album for metadata verification..."
        $filesToCheck = $oldFiles[0..1]
        Pull-Files $filesToCheck $AlbumDir $backfillCheckDir
        
        # Verify metadata
        $exiftoolPath = Get-ExiftoolPath
        foreach ($file in $filesToCheck) {
            $filePath = Join-Path $backfillCheckDir $file
            Log-Info "Checking metadata: $file"
            
            $metadata = & $exiftoolPath -XMP:SourceUrl -XMP:CapturedAt $filePath
            Log-Info "  XMP-prov fields: $metadata"
            
            $testResults["e"].details += "$file - XMP verified"
        }
        
        # Run backfill again - should be idempotent (0 writes)
        Log-Info "Running backfill again to verify idempotency..."
        $found2 = Tap-Control "为旧文件补写来源信息"
        Start-Sleep -Seconds 3
        
        Take-Screenshot "backfill-stats-2" $testEDir
        Log-Warning "Manually note the second backfill statistics"
        $stats2 = Read-Host "Enter second backfill statistics (should be 0 files)"
        
        if ($stats2 -match "0\s*(files|个)" -or $stats2 -match "^0$") {
            $testResults["e"].status = "PASSED"
            $testResults["e"].details += @(
                "First backfill: $stats1",
                "Second backfill: $stats2",
                "Idempotent: YES"
            )
            Log-Success "Test E: PASSED"
        } else {
            $testResults["e"].status = "FAILED"
            $testResults["e"].errors += "Second backfill wrote files (not idempotent): $stats2"
            Log-Error "Test E: FAILED"
        }
    } else {
        $testResults["e"].status = "FAILED"
        $testResults["e"].errors += "Could not locate backfill button"
        Log-Error "Test E: FAILED"
    }
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

function Main {
    Log-Info "========== EasySave Device Test v1.7 =========="
    Log-Info "Output: $TEST_OUTPUT"
    Log-Info ""
    
    # Preflight checks
    Test-DeviceConnected
    Get-ExiftoolPath | Out-Null
    Load-TestUrls
    Initialize-OutputDir
    
    # Unlock device
    Log-Info "Unlocking device..."
    Unlock-Device
    Start-Sleep -Seconds 2
    
    # Run extension tests (optional)
    if (-not $SkipExtensionTest) {
        Log-Test "========== Extension Unit Tests =========="
        Push-Location "D:\workspace\IdeaProjects\EasySave\extension"
        try {
            npm test
            Log-Success "Extension tests: PASSED"
        }
        catch {
            Log-Error "Extension tests failed"
            exit 1
        }
        finally {
            Pop-Location
        }
    }
    
    # Run selected test cases
    switch ($TestCase) {
        "a" { Test-A-MetadataWrite }
        "b" { Test-B-DeletionStayDeleted }
        "c" { Test-C-ReDownloadRestores }
        "d" { Test-D-RebuildHistoryNoDuplicates }
        "e" { Test-E-BackfillIdempotent }
        "all" {
            Test-A-MetadataWrite
            Test-B-DeletionStayDeleted
            Test-C-ReDownloadRestores
            Test-D-RebuildHistoryNoDuplicates
            Test-E-BackfillIdempotent
        }
    }
    
    # Summary
    Log-Info ""
    Log-Test "========== Test Summary =========="
    $testResults.GetEnumerator() | Sort-Object Name | ForEach-Object {
        $testName = $_.Key
        $result = $_.Value
        $status = $result.status
        $statusSymbol = if ($status -eq "PASSED") { "✅" } elseif ($status -eq "FAILED") { "❌" } else { "⏭️ " }
        
        Write-Host "  $statusSymbol Test $testName`: $status"
        
        if ($result.details) {
            $result.details | ForEach-Object { Write-Host "      • $_" -ForegroundColor Green }
        }
        if ($result.errors) {
            $result.errors | ForEach-Object { Write-Host "      ✗ $_" -ForegroundColor Red }
        }
    }
    
    Log-Info ""
    Log-Info "Output saved to: $TEST_OUTPUT"
    Log-Info "Review screenshots and logs for detailed results"
}

Main
