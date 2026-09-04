param(
    [string]$BaseUrl = 'https://liuhetong888.com',
    # 推送网关根地址：编译为 Matrix Pusher 的 data.url
    # （AppConfig.sygnalPushGatewayUrl）。留空 = 不编译网关地址，
    # 客户端不注册 pusher（docs/PUSH_SETUP.md）。
    [string]$SygnalUrl = '',
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
if (-not $ValidateOnly) {
    # 域名能力探测（0.3.29 二次事故教训）：App 编译进哪个 origin，
    # 哪个就必须真实代理业务 API 与 Matrix。www 域名只服务静态官网，
    # 误传 www 会让全部登录/同步请求拿到落地页 HTML。
    foreach ($probe in @('/api/v1/health/live', '/_matrix/client/versions')) {
        try {
            $resp = Invoke-WebRequest -Uri ($origin + $probe) -UseBasicParsing -TimeoutSec 20
            $contentType = [string]$resp.Headers['Content-Type']
            if ($contentType -notmatch 'json') {
                throw "origin probe $probe returned Content-Type '$contentType' (expected JSON); $origin does not proxy the app API surface"
            }
        }
        catch {
            throw "origin probe failed for ${probe}: $($_.Exception.Message). $origin is not usable as the app origin"
        }
    }
    Write-Output "ORIGIN_PROBE_OK $origin"
}
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
# 推送网关 dart-define（可选）：仅在显式传入时编译进产物。
$sygnalDefine = @()
if (-not [string]::IsNullOrWhiteSpace($SygnalUrl)) {
    Assert-PublicBaseUrl $SygnalUrl
    $sygnalDefine = @("--dart-define=LIUHETONG_SYGNAL_URL=$SygnalUrl")
}
$getuiDefine = @()
if (-not [string]::IsNullOrWhiteSpace($GetuiUrl)) {
    Assert-PublicBaseUrl $GetuiUrl
    $getuiDefine = @("--dart-define=LIUHETONG_GETUI_URL=$GetuiUrl")
}
# Release builds are split per ABI so the public download ships one CPU
# architecture instead of a 3x-heavy fat APK.
if ($BuildMode -eq 'Release') {
    $arguments = @(
        'build', 'apk', $modeArgument, '--flavor', 'standard', '--split-per-abi',
        "--dart-define=LIUHETONG_BUSINESS_API_URL=$origin",
        "--dart-define=LIUHETONG_MATRIX_HOMESERVER=$origin"
    ) + $sygnalDefine + $getuiDefine + @(
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
    ) + $sygnalDefine + $getuiDefine
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

# 清单版本守卫（0.3.29 发布事故教训）：aapt 读取 APK 内部
# versionName/versionCode 并与 pubspec 期望值比对，不一致即中止——
# 防止把输出目录里残留的旧构建产物（文件名/内容错位）当作新包发布。
function Assert-ApkManifestVersion {
    param([string]$ApkPath, [string]$ExpectedVersionName, [int]$ExpectedVersionCode, [string]$Label)
    $aaptPath = $null
    $sdkBuildTools = Join-Path $env:LOCALAPPDATA 'Android\Sdk\build-tools'
    if (Test-Path -LiteralPath $sdkBuildTools) {
        $aaptPath = (Get-ChildItem -LiteralPath $sdkBuildTools -Filter 'aapt.exe' -Recurse -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending | Select-Object -First 1).FullName
    }
    if (-not $aaptPath) {
        $aaptCommand = Get-Command aapt -ErrorAction SilentlyContinue
        if ($aaptCommand) { $aaptPath = $aaptCommand.Source }
    }
    if (-not $aaptPath) { throw "aapt.exe not found under $sdkBuildTools; cannot verify APK manifest version" }
    $badging = (& $aaptPath dump badging $ApkPath 2>$null | Select-Object -First 1)
    if (-not $badging -or $badging -notmatch "versionCode='(\d+)' versionName='([^']+)'") {
        throw "aapt could not parse manifest of $ApkPath"
    }
    $actualCode = [int]$Matches[1]; $actualName = $Matches[2]
    if ($actualName -ne $ExpectedVersionName -or $actualCode -ne $ExpectedVersionCode) {
        throw ("APK manifest mismatch ({0}) {1}: expected {2}+code{3}, got {4}+code{5}. " +
               'Stale artifact in flutter-apk output directory?') -f
               $Label, $ApkPath, $ExpectedVersionName, $ExpectedVersionCode, $actualName, $actualCode
    }
    Write-Output "APK_MANIFEST_OK $Label $actualName/$actualCode"
}

# libapp.so origin 断言：dart-define 的两个 origin 必须编译进产物。
# （混淆保留字符串字面量；二进制 grep 即可。）
function Assert-LibappOrigin {
    param([string]$ApkPath, [string]$ExpectedOrigin)
    $soFile = Join-Path ([IO.Path]::GetTempPath()) ("libapp-" + [IO.Path]::GetFileNameWithoutExtension($ApkPath) + ".so")
    Copy-Item -LiteralPath $ApkPath -Destination ($soFile + ".zip") -Force
    Expand-Archive -LiteralPath ($soFile + ".zip") -DestinationPath ($soFile + ".dir") -Force
    $so = Get-ChildItem -LiteralPath ($soFile + ".dir") -Recurse -Filter 'libapp.so' | Select-Object -First 1
    if (-not $so) { throw "libapp.so not found inside $ApkPath" }
    $bytes = [IO.File]::ReadAllBytes($so.FullName)
    $text = [Text.Encoding]::ASCII.GetString($bytes)
    if (-not $text.Contains($ExpectedOrigin)) {
        throw "libapp.so of $ApkPath does not contain compiled origin '$ExpectedOrigin'; dart-defines did not take effect"
    }
    Remove-Item -LiteralPath ($soFile + ".zip"), ($soFile + ".dir") -Recurse -Force -ErrorAction SilentlyContinue
    Write-Output "APK_ORIGIN_OK $([IO.Path]::GetFileName($ApkPath)) $ExpectedOrigin"
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
        'arm64-v8a'   = @{ source = 'app-arm64-v8a-standard-release.apk';   versionCodePrefix = 2000; published = "ChatFlow-$versionName-arm64.apk" }
        'armeabi-v7a' = @{ source = 'app-armeabi-v7a-standard-release.apk'; versionCodePrefix = 1000; published = "ChatFlow-$versionName-arm32.apk" }
        'x86_64'      = @{ source = 'app-x86_64-standard-release.apk';      versionCodePrefix = 4000; published = "ChatFlow-$versionName-x86_64.apk" }
    }
    foreach ($abi in $abiArtifacts.Keys) {
        $candidate = Join-Path $mobileRoot "build\app\outputs\flutter-apk\$($abiArtifacts[$abi].source)"
        if (-not (Test-Path -LiteralPath $candidate)) {
            throw "Expected per-ABI APK was not produced: $candidate"
        }
        $published = Join-Path $mobileRoot "build\app\outputs\flutter-apk\$($abiArtifacts[$abi].published)"
        Copy-Item -LiteralPath $candidate -Destination $published -Force
        Assert-ApkManifestVersion -ApkPath $published -ExpectedVersionName $versionName -ExpectedVersionCode ([int]$abiArtifacts[$abi].versionCodePrefix + [int]$versionBuild) -Label $abi
        Assert-LibappOrigin -ApkPath $published -ExpectedOrigin $origin
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
