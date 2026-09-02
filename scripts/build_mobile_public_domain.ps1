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
# Release builds are split per ABI so the public download ships one CPU
# architecture instead of a 3x-heavy fat APK.
if ($BuildMode -eq 'Release') {
    $arguments = @(
        'build', 'apk', $modeArgument, '--split-per-abi',
        "--dart-define=LIUHETONG_BUSINESS_API_URL=$origin",
        "--dart-define=LIUHETONG_MATRIX_HOMESERVER=$origin",
        # Dart 代码混淆 + 符号分离：去除 libapp.so 内明文字符串/符号，
        # 降低安全厂商灰度启发式误报；符号表存档用于崩溃还原。
        "--obfuscate",
        "--split-debug-info=$mobileRoot\build\symbols"
    )
}
else {
    $arguments = @(
        'build', 'apk', $modeArgument,
        "--dart-define=LIUHETONG_BUSINESS_API_URL=$origin",
        "--dart-define=LIUHETONG_MATRIX_HOMESERVER=$origin"
    )
}

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

# The public download name follows the pubspec release version, e.g.
# ChatFlow-0.3.0.apk; bumping `version:` in pubspec.yaml rolls the name.
$pubspec = Get-Content -LiteralPath (Join-Path $mobileRoot 'pubspec.yaml') -Raw -Encoding UTF8
if ($pubspec -notmatch '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$') {
    throw 'pubspec.yaml must declare version: X.Y.Z+build'
}
$versionName = $Matches[1]
$versionBuild = $Matches[2]

if ($BuildMode -eq 'Release') {
    # Public names carry the ABI suffix, e.g. ChatFlow-0.3.0-arm64.apk;
    # the landing page offers arm64 (default), arm32 and x86_64.
    $abiArtifacts = [ordered]@{
        'arm64-v8a'   = @{ source = 'app-arm64-v8a-release.apk';   published = "ChatFlow-$versionName-arm64.apk" }
        'armeabi-v7a' = @{ source = 'app-armeabi-v7a-release.apk'; published = "ChatFlow-$versionName-arm32.apk" }
        'x86_64'      = @{ source = 'app-x86_64-release.apk';      published = "ChatFlow-$versionName-x86_64.apk" }
    }
    foreach ($abi in $abiArtifacts.Keys) {
        $candidate = Join-Path $mobileRoot "build\app\outputs\flutter-apk\$($abiArtifacts[$abi].source)"
        if (-not (Test-Path -LiteralPath $candidate)) {
            throw "Expected per-ABI APK was not produced: $candidate"
        }
        $published = Join-Path $mobileRoot "build\app\outputs\flutter-apk\$($abiArtifacts[$abi].published)"
        Copy-Item -LiteralPath $candidate -Destination $published -Force
    }
    # arm64-v8a is the default public artifact; modern phones are arm64-only.
    $apk = Join-Path $mobileRoot "build\app\outputs\flutter-apk\$($abiArtifacts['arm64-v8a'].published)"
}
else {
    $apk = Join-Path $mobileRoot 'build\app\outputs\flutter-apk\app-debug.apk'
}

if (-not (Test-Path -LiteralPath $apk)) {
    throw "Expected APK was not produced: $apk"
}

$file = Get-Item -LiteralPath $apk
$hash = Get-FileHash -LiteralPath $apk -Algorithm SHA256
Write-Output "APK=$($file.FullName)"
Write-Output "APK_BYTES=$($file.Length)"
Write-Output "APK_SHA256=$($hash.Hash)"
if ($BuildMode -eq 'Release') {
    foreach ($abi in $abiArtifacts.Keys) {
        Write-Output "PUBLISHED_ABI=$abi -> $($abiArtifacts[$abi].published)"
    }
}
Write-Output "APK_VERSION=$versionName+$versionBuild"
Write-Output "PUBLIC_ORIGIN=$origin"
Write-Output "BUILD_MODE=$BuildMode"

if ($Install) {
    $adb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
    if (-not (Test-Path -LiteralPath $adb)) {
        $adbCommand = Get-Command adb -ErrorAction SilentlyContinue
        if (-not $adbCommand) { throw 'adb executable was not found' }
        $adb = $adbCommand.Source
    }
    # Pick the split matching the device so emulator acceptance keeps
    # working (emulators are x86_64 while the public artifact is arm64).
    $deviceAbi = (& $adb -s $DeviceId shell getprop ro.product.cpu.abi).Trim()
    $deviceApk = $apk
    if ($BuildMode -eq 'Release' -and $abiArtifacts.Contains($deviceAbi)) {
        $deviceApk = Join-Path $mobileRoot "build\app\outputs\flutter-apk\$($abiArtifacts[$deviceAbi].source)"
    }
    & $adb -s $DeviceId install --no-streaming -r $deviceApk
    if ($LASTEXITCODE -ne 0) { throw "APK installation failed for $DeviceId" }
    Write-Output "INSTALLED_DEVICE=$DeviceId ($deviceAbi)"
}
