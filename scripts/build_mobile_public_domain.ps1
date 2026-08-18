param(
    [string]$BaseUrl = 'https://liuhetong888.com',
    [ValidateSet('Release', 'Debug')]
    [string]$BuildMode = 'Release',
    [switch]$ValidateOnly,
    [switch]$Install,
    [string]$DeviceId = 'emulator-5554'
)

$ErrorActionPreference = 'Stop'

function Assert-PublicBaseUrl([string]$Value) {
    $uri = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri)) {
        throw 'BaseUrl must be an absolute URI'
    }
    if ($uri.Scheme -ne 'https') {
        throw 'BaseUrl must use HTTPS'
    }
    if (-not $uri.IsDefaultPort -or $uri.Port -ne 443) {
        throw 'BaseUrl must use the default HTTPS port'
    }
    if ($uri.AbsolutePath -ne '/' -or $uri.Query -or $uri.Fragment -or $uri.UserInfo) {
        throw 'BaseUrl must be an origin without path, query, fragment, or credentials'
    }
    if ([Uri]::CheckHostName($uri.Host) -ne [UriHostNameType]::Dns -or
        $uri.Host -eq 'localhost' -or $uri.Host -notmatch '\.') {
        throw 'BaseUrl must use a public DNS hostname, not localhost or an IP literal'
    }
    return $uri.GetLeftPart([UriPartial]::Authority)
}

$origin = Assert-PublicBaseUrl $BaseUrl
if ($ValidateOnly) {
    Write-Output "Public mobile origin valid: $origin"
    exit 0
}

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$mobileRoot = Join-Path $root 'apps\mobile_flutter'
$flutterCommand = Get-Command flutter -ErrorAction SilentlyContinue
$flutter = if ($flutterCommand) {
    $flutterCommand.Source
}
elseif (Test-Path -LiteralPath 'C:\src\flutter\bin\flutter.bat') {
    'C:\src\flutter\bin\flutter.bat'
}
else {
    throw 'Flutter executable was not found'
}

$modeArgument = "--$($BuildMode.ToLowerInvariant())"
$arguments = @(
    'build', 'apk', $modeArgument,
    "--dart-define=LIUHETONG_BUSINESS_API_URL=$origin",
    "--dart-define=LIUHETONG_MATRIX_HOMESERVER=$origin"
)

if ($BuildMode -eq 'Release') {
    $manifest = Get-Content -LiteralPath (Join-Path $mobileRoot 'android\app\src\main\AndroidManifest.xml') -Raw -Encoding UTF8
    if ($manifest -notmatch 'android:usesCleartextTraffic="false"') {
        throw 'Android Release manifest must disable cleartext traffic'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $mobileRoot 'android\key.properties'))) {
        throw 'Release signing configuration is not available; use -BuildMode Debug only for emulator acceptance'
    }
}

Push-Location $mobileRoot
try {
    & $flutter @arguments
    if ($LASTEXITCODE -ne 0) { throw 'Flutter APK build failed' }
}
finally {
    Pop-Location
}

$apkName = if ($BuildMode -eq 'Release') { 'app-release.apk' } else { 'app-debug.apk' }
$apk = Join-Path $mobileRoot "build\app\outputs\flutter-apk\$apkName"
if (-not (Test-Path -LiteralPath $apk)) {
    throw "Expected APK was not produced: $apk"
}

$file = Get-Item -LiteralPath $apk
$hash = Get-FileHash -LiteralPath $apk -Algorithm SHA256
Write-Output "APK=$($file.FullName)"
Write-Output "APK_BYTES=$($file.Length)"
Write-Output "APK_SHA256=$($hash.Hash)"
Write-Output "PUBLIC_ORIGIN=$origin"
Write-Output "BUILD_MODE=$BuildMode"

if ($Install) {
    $adb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
    if (-not (Test-Path -LiteralPath $adb)) {
        $adbCommand = Get-Command adb -ErrorAction SilentlyContinue
        if (-not $adbCommand) { throw 'adb executable was not found' }
        $adb = $adbCommand.Source
    }
    & $adb -s $DeviceId install --no-streaming -r $apk
    if ($LASTEXITCODE -ne 0) { throw "APK installation failed for $DeviceId" }
    Write-Output "INSTALLED_DEVICE=$DeviceId"
}
