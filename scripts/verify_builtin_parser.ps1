# Hard gate for the parser bundled in the App.
#
# 1. Without -ApkPath: the working tree must agree with
#    config/parser-release.json, spec/PARSER_VERSION, the sha256 of
#    app/assets/parser/parser.js and the generated ParserVersion constant.
# 2. With -ApkPath: the parser.js and builtin-manifest.json *inside the APK*
#    must match those same values, so a delivered artifact cannot report a
#    different builtin version than the release it was built from.
#
# Read-only: the APK is copied to a temporary directory only to read the two
# assets, and that directory is removed before returning.
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$ApkPath
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$problems = New-Object System.Collections.Generic.List[string]

function Get-Sha256([string]$path) {
    (Get-FileHash -Algorithm SHA256 -Path $path).Hash.ToLowerInvariant()
}

# PowerShell 5.1 reads files in the ANSI code page by default, which garbles the
# Chinese notices in the JSON and makes ConvertFrom-Json fail.
function Read-Utf8([string]$path) {
    [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
}

$release = Read-Utf8 (Join-Path $repoRoot 'config/parser-release.json') | ConvertFrom-Json
$parserVersion = (Read-Utf8 (Join-Path $repoRoot 'spec/PARSER_VERSION')).Trim()
$manifestPath = Join-Path $repoRoot 'app/assets/parser/builtin-manifest.json'
$parserPath = Join-Path $repoRoot 'app/assets/parser/parser.js'
$manifest = Read-Utf8 $manifestPath | ConvertFrom-Json
$expectedSha = Get-Sha256 $parserPath
$expectedUrl = $release.parserUrlTemplate.Replace('{parserVersion}', $parserVersion)
$dartPath = Join-Path $repoRoot 'app/lib/generated/parser_version.dart'
$dartMatch = [regex]::Match((Read-Utf8 $dartPath), "version = '([^']+)'")

if ($manifest.manifestVersion -ne $release.manifestVersion) {
    $problems.Add("tree manifestVersion=$($manifest.manifestVersion) expected=$($release.manifestVersion)")
}
if ($manifest.parserVersion -ne $parserVersion) {
    $problems.Add("tree parserVersion=$($manifest.parserVersion) expected=$parserVersion")
}
if ($manifest.sha256 -ne $expectedSha) {
    $problems.Add("tree parser.js sha256=$expectedSha does not match the manifest")
}
if ($manifest.parserUrl -ne $expectedUrl) {
    $problems.Add("tree parserUrl=$($manifest.parserUrl) expected=$expectedUrl")
}
if (-not $dartMatch.Success -or $dartMatch.Groups[1].Value -ne $parserVersion) {
    $problems.Add("lib/generated/parser_version.dart does not declare $parserVersion")
}

$source = @{ Version = $manifest.parserVersion; ManifestVersion = $manifest.manifestVersion; Sha256 = $expectedSha }

if ($ApkPath) {
    if (-not (Test-Path -LiteralPath $ApkPath)) {
        Write-Error "APK not found: $ApkPath"
        exit 1
    }
    $apk = (Resolve-Path -LiteralPath $ApkPath).Path
    $temp = Join-Path ([IO.Path]::GetTempPath()) ("easysave-apk-check-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temp | Out-Null
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($apk)
        try {
            $entries = $zip.Entries | Where-Object { $_.FullName -like '*assets/parser/*' }
            $parserEntry = $entries | Where-Object { $_.FullName -like '*/assets/parser/parser.js' } | Select-Object -First 1
            $manifestEntry = $entries | Where-Object { $_.FullName -like '*/assets/parser/builtin-manifest.json' } | Select-Object -First 1
            if (-not $parserEntry -or -not $manifestEntry) {
                $problems.Add('APK does not contain assets/parser/parser.js and builtin-manifest.json')
            }
            else {
                $apkParser = Join-Path $temp 'parser.js'
                $apkManifest = Join-Path $temp 'builtin-manifest.json'
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($parserEntry, $apkParser, $true)
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($manifestEntry, $apkManifest, $true)
                $apkSha = Get-Sha256 $apkParser
                $apkManifestJson = Read-Utf8 $apkManifest | ConvertFrom-Json
                if ($apkManifestJson.manifestVersion -ne $release.manifestVersion) {
                    $problems.Add("apk manifestVersion=$($apkManifestJson.manifestVersion) expected=$($release.manifestVersion)")
                }
                if ($apkManifestJson.parserVersion -ne $parserVersion) {
                    $problems.Add("apk parserVersion=$($apkManifestJson.parserVersion) expected=$parserVersion")
                }
                if ($apkManifestJson.sha256 -ne $apkSha) {
                    $problems.Add("apk parser.js sha256=$apkSha does not match its manifest")
                }
                if ($apkSha -ne $expectedSha) {
                    $problems.Add("apk parser.js differs from app/assets/parser/parser.js")
                }
                $source = @{
                    Version         = $apkManifestJson.parserVersion
                    ManifestVersion = $apkManifestJson.manifestVersion
                    Sha256          = $apkSha
                }
            }
        }
        finally {
            $zip.Dispose()
        }
    }
    finally {
        Remove-Item -Recurse -Force -LiteralPath $temp -ErrorAction SilentlyContinue
    }
}

if ($problems.Count -gt 0) {
    Write-Host 'Bundled parser check FAILED:'
    foreach ($problem in $problems) { Write-Host "  - $problem" }
    Write-Host 'Update config/parser-release.json + spec/PARSER_VERSION, then run npm run build:parser in extension/.'
    exit 1
}

$origin = if ($ApkPath) { 'apk' } else { 'tree' }
Write-Host "Bundled parser ok ($origin): version=$($source.Version) manifestVersion=$($source.ManifestVersion) sha256=$($source.Sha256)"
exit 0
