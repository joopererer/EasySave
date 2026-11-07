[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$GradleUserHome,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$FlutterArguments
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $GradleUserHome) {
    $GradleUserHome = Join-Path $repoRoot 'app/build/v110b/gradle-home'
}
# Refuse to build an APK whose bundled parser no longer matches the declared
# release (config/parser-release.json + spec/PARSER_VERSION).
$parserCheck = Join-Path $PSScriptRoot 'verify_builtin_parser.ps1'
& $parserCheck
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$previousGradleUserHome = $env:GRADLE_USER_HOME
$buildExitCode = 1
try {
    $env:GRADLE_USER_HOME = [IO.Path]::GetFullPath($GradleUserHome)
    Write-Host "Gradle user home: $env:GRADLE_USER_HOME"
    $flutter = (Get-Command flutter.bat -ErrorAction Stop).Source
    New-Item -ItemType Directory -Path (Join-Path $repoRoot 'app/build') -Force > $null
    Push-Location (Join-Path $repoRoot 'app')
    try {
        $buildLog = Join-Path $repoRoot 'app/build/android-release-build.log'
        # Native stderr may contain warnings even when the build succeeds.
        $ErrorActionPreference = 'Continue'
        try {
            & $flutter build apk --release @FlutterArguments 2>&1 |
                Tee-Object -FilePath $buildLog
            $buildExitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = 'Stop'
        }
    } finally {
        Pop-Location
    }
} finally {
    $env:GRADLE_USER_HOME = $previousGradleUserHome
}
exit $buildExitCode
