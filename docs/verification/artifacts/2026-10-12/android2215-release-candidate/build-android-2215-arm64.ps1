param(
    [Parameter(Mandatory)][string]$Worktree,
    [string]$OutputRoot = $PSScriptRoot,
    [Parameter(Mandatory)][string]$MobileManifest,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedMobileManifestSha256,
    [Parameter(Mandatory)][ValidateRange(1, 999999)][int]$ConfirmedProductionAndroidBuild,
    [Parameter(Mandatory)][ValidateRange(1, 999999)][int]$ConfirmedProductionIosBuild,
    [Parameter(Mandatory)][DateTimeOffset]$ProductionCheckedAtUtc,
    [string]$RunId = ('run-' + (Get-Date -Format 'yyyyMMdd-HHmmss')),
    [ValidateSet('W')][string]$SourceDrive = 'W',
    [ValidatePattern('^[R-X]$')][string]$ArtifactDrive = 'V',
    [switch]$Execute,
    [switch]$PreflightOnly
)

$ErrorActionPreference = 'Stop'
$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8
$env:PYTHONUTF8 = '1'
$env:PYTHONIOENCODING = 'utf-8'
$env:PYTHONDONTWRITEBYTECODE = '1'

# ARM64 candidate only. This script never installs, uploads, or publishes an APK.
# Preserve full Material/Cupertino fonts for dynamic icons; still normal AOT release.
# A normal `flutter pub get` and freeze_mobile_input.py create must precede it.
$version = '0.4.46'
$build = 2215
$expectedCertificate = '75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff'
$flutter = 'C:\src\flutter\bin\flutter.bat'
$apktool = 'C:\Users\Administrator\.codex\worktrees\im-reliability\StarChat\docs\verification\artifacts\2026-10-12\android2214-media-regression\tools\apktool_2.12.1.jar'
$signer = Join-Path $PSScriptRoot 'tools\sign-existing-identity.ps1'
$verificationReference = Join-Path $PSScriptRoot 'tools'
$semanticVerifier = Join-Path $verificationReference 'verify_rebuild.py'
$lockVerifier = Join-Path $PSScriptRoot 'verify_lock_closure.py'
$lockBaseline = Join-Path $PSScriptRoot 'lock-closure-baseline.json'
$toolIdentities = Join-Path $PSScriptRoot 'candidate-tool-identities.json'
$javaHome = 'C:\Program Files\Microsoft\jdk-17.0.20.8-hotspot'
$java = Join-Path $javaHome 'bin\java.exe'
$devRegistrantCorrection = Join-Path $PSScriptRoot 'strip_dev_plugin_registrant.py'
$buildTools = 'C:\Users\Administrator\AppData\Local\Android\Sdk\build-tools\36.0.0'
$aapt = Join-Path $buildTools 'aapt.exe'
$zipalign = Join-Path $buildTools 'zipalign.exe'
$apksigner = Join-Path $buildTools 'apksigner.bat'
$signingDir = Join-Path $env:USERPROFILE '.chatflow-signing\diagnostic-20260905'
$keystore = Join-Path $signingDir 'diagnostic.p12'
$protectedPassword = Join-Path $signingDir 'password.dpapi'
$freezeHelper = Join-Path $PSScriptRoot 'freeze_mobile_input.py'

function Require-File([string]$Path, [string]$Description) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or
        (Get-Item -LiteralPath $Path).Length -le 0) {
        throw "$Description unavailable or empty: $Path"
    }
}

function Assert-PathAtOrBelow([string]$Path, [string]$Root) {
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    if ($fullPath -ne $fullRoot -and
        -not $fullPath.StartsWith(($fullRoot + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)) {
        throw "Verification output must remain below $fullRoot"
    }
}

function Assert-NoReparseDirectory([string]$Path) {
    $fullPath = [IO.Path]::GetFullPath($Path)
    $cursor = [IO.Path]::GetPathRoot($fullPath)
    foreach ($part in $fullPath.Substring($cursor.Length).Split(@('\', '/'), [StringSplitOptions]::RemoveEmptyEntries)) {
        $cursor = Join-Path $cursor $part
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Verification output path contains a file or reparse point: $cursor"
        }
    }
}

function Assert-StableSignerPresent {
    # The historical signer can create a new key if both files are missing.
    # Never call it without both existing parts of the user-tested identity.
    Require-File $keystore 'Stable P12 signing key'
    Require-File $protectedPassword 'DPAPI protected signing password'
}

function Get-SubstTarget([string]$Letter) {
    $lines = @(& subst.exe)
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect subst mappings' }
    $matching = @($lines | Where-Object { $_ -match ('^(?i:' + [regex]::Escape($Letter) + '):\\: => ') })
    if ($matching.Count -gt 1) { throw "Ambiguous subst mapping for ${Letter}:" }
    if ($matching.Count -eq 0) { return $null }
    if ($matching[0] -notmatch '^[A-Za-z]:\\: => (.+)$') { throw 'Unexpected subst output' }
    return [IO.Path]::GetFullPath($Matches[1]).TrimEnd('\', '/')
}

function Ensure-Subst([string]$Letter, [string]$Target) {
    $wanted = [IO.Path]::GetFullPath($Target).TrimEnd('\', '/')
    $current = Get-SubstTarget $Letter
    if ($null -ne $current) {
        if ($current -ne $wanted) { throw "${Letter}: already maps to another location" }
        return $false
    }
    $label = "${Letter}:"
    if (Test-Path -LiteralPath ($label + '\')) { throw "$label is already a real drive" }
    & subst.exe $label $wanted | Out-Null
    if ($LASTEXITCODE -ne 0 -or (Get-SubstTarget $Letter) -ne $wanted) {
        throw "Failed to map $label to the selected path"
    }
    return $true
}

function Assert-ReleaseIdentity([string]$Log) {
    $badging = Get-Content -LiteralPath $Log -Raw -Encoding utf8
    if ($badging -notmatch "(?m)^package: name='com\.liuhetong\.mobile' versionCode='$build' versionName='$([regex]::Escape($version))'") {
        throw "Unexpected package/version in $Log"
    }
    if ($badging -match '(?m)^application-debuggable') { throw "Release APK must not be debuggable: $Log" }
    if ($badging -notmatch "(?m)^native-code: 'arm64-v8a'\s*$") { throw "Release APK must contain only arm64-v8a: $Log" }
}

if ($Execute -and $PreflightOnly) { throw 'Execute and PreflightOnly are mutually exclusive' }
foreach ($suppliedPath in @($Worktree, $OutputRoot, $MobileManifest)) {
    if ($suppliedPath -match '[%!&|<>^"\r\n]') { throw 'Shell metacharacters are forbidden in build paths' }
}
if ($RunId -notmatch '^run-[0-9]{8}-[0-9]{6}(-[a-z0-9]+)?$') {
    throw 'RunId must be run-YYYYMMDD-HHMMSS with optional lowercase suffix'
}
if ($SourceDrive -eq $ArtifactDrive) { throw 'Source and artifact drives must be different' }
$taskRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\', '/')
$repo = (Resolve-Path -LiteralPath $Worktree -ErrorAction Stop).Path.TrimEnd('\', '/')
$output = [IO.Path]::GetFullPath($OutputRoot).TrimEnd('\', '/')
Assert-PathAtOrBelow $output $taskRoot
if (-not (Test-Path -LiteralPath $output -PathType Container)) { throw 'OutputRoot must exist before preflight' }
Assert-NoReparseDirectory $output
if (-not (Test-Path -LiteralPath (Join-Path $repo '.git'))) { throw 'Worktree has no Git identity' }
$mobileRoot = Join-Path $repo 'apps\mobile_flutter'
$pubspecPath = Join-Path $mobileRoot 'pubspec.yaml'
$configPath = Join-Path $mobileRoot 'lib\core\app_config.dart'
Require-File $pubspecPath 'Flutter pubspec'
Require-File $configPath 'App version configuration'
Require-File (Join-Path $mobileRoot 'pubspec.lock') 'Flutter dependency lockfile'
Require-File (Join-Path $mobileRoot '.dart_tool\package_config.json') 'Generated Flutter package configuration'
Require-File (Join-Path $mobileRoot '.flutter-plugins-dependencies') 'Generated Flutter plugin dependencies'
Require-File $flutter 'Flutter SDK'
Require-File $apktool 'Apktool 2.12.1 jar'
Require-File $signer 'Stable identity signing script'
Require-File $semanticVerifier 'Conventional APK semantic verifier'
Require-File $lockVerifier 'Native lock-screen verifier'
Require-File $devRegistrantCorrection 'Bounded generated dev-plugin correction'
Require-File $freezeHelper 'Mobile input freeze helper'
Require-File $lockBaseline 'Frozen static lock closure'
Require-File $toolIdentities 'Pinned candidate tools'
Require-File $java 'Pinned JDK17 executable'
$pinnedTools = Get-Content -LiteralPath $toolIdentities -Raw -Encoding utf8 | ConvertFrom-Json
foreach ($entry in $pinnedTools.files.PSObject.Properties) {
    $toolPath = Join-Path $PSScriptRoot $entry.Name
    Require-File $toolPath 'Frozen candidate helper'
    if ((Get-FileHash -LiteralPath $toolPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $entry.Value) { throw 'Candidate helper identity drift' }
}
if ((Get-FileHash -LiteralPath $apktool -Algorithm SHA256).Hash.ToLowerInvariant() -cne $pinnedTools.apktool_sha256) { throw 'Apktool identity drift' }
$lockBaselineSha = (Get-FileHash -LiteralPath $lockBaseline -Algorithm SHA256).Hash.ToLowerInvariant()
Require-File (Join-Path $repo 'scripts\verify_android_release.py') 'Standard ARM64 release payload verifier'
$bumpScript = Join-Path $repo 'scripts\bump_version.ps1'
$versionContract = Join-Path $repo 'tests\mobile\test_app_build_contract.py'
Require-File $bumpScript 'Version bump script'
Require-File $versionContract 'Version contract test'
if ((Get-Content -LiteralPath $bumpScript -Raw -Encoding utf8) -notmatch 'compiledBuildNumber' -or
    (Get-Content -LiteralPath $versionContract -Raw -Encoding utf8) -notmatch 'compiledBuildNumber') {
    throw 'Worktree has old version tooling; integrate current MAIN bump script and contract test first'
}
foreach ($tool in @($aapt, $zipalign, $apksigner)) { Require-File $tool 'Android build-tools 36.0.0' }
Assert-StableSignerPresent
if (-not [string]::IsNullOrWhiteSpace($env:KEYSTORE_FILE) -or
    (Test-Path -LiteralPath (Join-Path $mobileRoot 'android\key.properties')) -or
    (Test-Path -LiteralPath (Join-Path $mobileRoot 'android\app\google-services.json'))) {
    throw 'Unexpected local Android signing or Firebase input; freeze and review it separately'
}
$pubspec = Get-Content -LiteralPath $pubspecPath -Raw -Encoding utf8
$appConfig = Get-Content -LiteralPath $configPath -Raw -Encoding utf8
if ($pubspec -notmatch '(?m)^version: 0\.4\.46\+2215\s*$' -or
    $appConfig -notmatch "appVersionName\s*=\s*'0\.4\.46'" -or
    $appConfig -notmatch 'compiledBuildNumber\s*=\s*2215\s*;') {
    throw 'Candidate pubspec.yaml and app_config.dart must both be 0.4.46+2215'
}
if ($ConfirmedProductionAndroidBuild -ne 2214 -or $ConfirmedProductionIosBuild -ne 2213) {
    throw 'Approved production baseline must be Android2214 and iOS2213'
}
$productionCheckAge = ([DateTimeOffset]::UtcNow - $ProductionCheckedAtUtc.ToUniversalTime()).TotalMinutes
if ($productionCheckAge -gt 30 -or $productionCheckAge -lt -2) {
    throw 'Production version check must be fresh (within 30 minutes)'
}
$manifestPath = (Resolve-Path -LiteralPath $MobileManifest -ErrorAction Stop).Path
Assert-PathAtOrBelow $manifestPath ([IO.Path]::GetFullPath((Join-Path $taskRoot '..')))
Require-File $manifestPath 'Frozen mobile manifest'
$freezePreflight = @(& py -3.12 $freezeHelper verify --repo $repo --manifest $manifestPath --expected-sha256 $ExpectedMobileManifestSha256)
if ($LASTEXITCODE -ne 0 -or $freezePreflight.Count -ne 1) { throw 'Frozen mobile input verification failed' }
$frozenInput = $freezePreflight[0] | ConvertFrom-Json
if ($frozenInput.version -ne $version -or $frozenInput.build -ne $build) { throw 'Frozen manifest version mismatch' }
# This task's clean worktree uses its own normal build directory. Never reuse
# the historical junction whose C:/S: aliases caused shared-output deletion.
$expectedBuildRoot = Join-Path $mobileRoot 'build'
if (Test-Path -LiteralPath $expectedBuildRoot) { Assert-NoReparseDirectory $expectedBuildRoot }
$bundleVerifier = Join-Path $PSScriptRoot 'verify_android_flutter_assets.py'
Require-File $bundleVerifier 'Complete Flutter resource verifier'
if (Test-Path -LiteralPath (Join-Path $output $RunId)) { throw 'Run directory already exists' }
$closurePreflight = @(& py -3.12 $lockVerifier --repo $repo --baseline $lockBaseline --expected-baseline-sha256 $lockBaselineSha)
if ($LASTEXITCODE -ne 0 -or $closurePreflight.Count -ne 1) { throw 'Native/dependency source closure changed; no reuse' }
if (-not $Execute) {
    [ordered]@{
        preflight = 'passed'; build_started = $false; execute_required = $true
        worktree = $repo
        output_root = $output
        version = $version
        build = $build
        source_commit = $frozenInput.source_commit
        mobile_manifest_sha256 = $frozenInput.manifest_sha256
        mobile_file_count = $frozenInput.file_count
        isolated_build_cache = $expectedBuildRoot
        production_android_build = $ConfirmedProductionAndroidBuild
        production_ios_build = $ConfirmedProductionIosBuild
        production_checked_at_utc = $ProductionCheckedAtUtc.ToUniversalTime().ToString('o')
    } | ConvertTo-Json
    return
}

$sourceMappingOwned = $false
$artifactMappingOwned = $false
$originalGradleOpts = $env:GRADLE_OPTS
$originalParallelDebug = $env:ORG_GRADLE_PROJECT_chatflowParallelDebug
$originalPubHost = $env:PUB_HOSTED_URL
$originalJavaHome = $env:JAVA_HOME
$originalPath = $env:Path
try {
    $env:PUB_HOSTED_URL = 'https://pub.dev'
    $env:JAVA_HOME = $javaHome
    $env:Path = (Join-Path $javaHome 'bin') + ';' + $originalPath
    if (-not (Test-Path -LiteralPath $expectedBuildRoot -PathType Container)) { New-Item -ItemType Directory -Path $expectedBuildRoot -ErrorAction Stop | Out-Null }
    Assert-NoReparseDirectory $expectedBuildRoot
    $sourceMappingOwned = Ensure-Subst $SourceDrive $repo
    $artifactMappingOwned = Ensure-Subst $ArtifactDrive $output
    $shortRepo = "${SourceDrive}:\"
    $shortOutput = "${ArtifactDrive}:\"
    $dest = Join-Path $shortOutput $RunId
    New-Item -ItemType Directory -Path $dest -ErrorAction Stop | Out-Null
    $steps = Join-Path $dest 'steps.tsv'
    [IO.File]::WriteAllText($steps, "step`texit_code`tlog`n", $utf8)

    function Invoke-NativeStep {
        param(
            [Parameter(Mandatory)][string]$Name,
            [Parameter(Mandatory)][string]$Command,
            [string[]]$Arguments = @(),
            [Parameter(Mandatory)][string]$LogName
        )
        $log = Join-Path $dest $LogName
        & $Command @Arguments *> $log
        $exitCode = $LASTEXITCODE
        [IO.File]::AppendAllText($steps, "$Name`t$exitCode`t$LogName`n", $utf8)
        if ($exitCode -ne 0) { throw "$Name failed with exit code $exitCode; inspect $log" }
    }

    Invoke-NativeStep 'apktool-version' $java @('-jar', $apktool, '--version') 'apktool-version.log'
    if ((Get-Content -LiteralPath (Join-Path $dest 'apktool-version.log') -Raw -Encoding utf8).Trim() -ne '2.12.1') {
        throw 'Unexpected Apktool version'
    }
    Invoke-NativeStep 'flutter-version' $flutter @('--version') 'flutter-version.log'
    Invoke-NativeStep 'java-version' $java @('-version') 'java-version.log'
    Invoke-NativeStep 'version-contract' 'py' @('-3.12', '-m', 'pytest', '-q', '-p', 'no:cacheprovider', (Join-Path $shortRepo 'tests\mobile\test_app_build_contract.py')) 'version-contract.log'
    $env:GRADLE_OPTS = '-Dorg.gradle.workers.max=2 -Dorg.gradle.project.chatflowParallelDebug=false'
    $defines = @(
        '--dart-define=LIUHETONG_MATRIX_HOMESERVER=https://liuhetong888.com',
        '--dart-define=LIUHETONG_BUSINESS_API_URL=https://liuhetong888.com',
        '--dart-define=LIUHETONG_GETUI_URL=https://liuhetong888.com',
        '--dart-define=CHATFLOW_PERFORMANCE_METRICS=true'
    )
    Remove-Item -LiteralPath Env:ORG_GRADLE_PROJECT_chatflowParallelDebug -ErrorAction SilentlyContinue
    $buildArguments = @(
        'build', 'apk', '--release', '--no-pub', '--flavor', 'standard',
        '--no-tree-shake-icons',
        '--target-platform', 'android-arm64', '-t', 'lib/main.dart',
        '--build-name', $version, '--build-number', "$build"
    ) + $defines
    [IO.File]::WriteAllText((Join-Path $dest 'flutter-arguments.json'), ($buildArguments | ConvertTo-Json), $utf8)
    # Current Flutter 3.44.9 skips platform registrant generation with --no-pub.
    # pub get creates the dev registration with releaseMode=false; remove only
    # the byte-exact known block from this candidate's ignored generated file.
    Invoke-NativeStep 'candidate-dev-registration-correction' 'py' @(
        '-3.12', $devRegistrantCorrection, '--mobile-root', $mobileRoot,
        '--expected-repo', $repo, '--mode', 'ensure-clean'
    ) 'dev-registration.json'
    $registrantReceipt = Get-Content -LiteralPath (Join-Path $dest 'dev-registration.json') -Raw -Encoding utf8 | ConvertFrom-Json
    Push-Location -LiteralPath (Join-Path $shortRepo 'apps\mobile_flutter')
    try {
        Invoke-NativeStep 'flutter-build-release' $flutter $buildArguments 'source-build.log'
    } finally {
        Pop-Location
    }
    # Stop if the SDK regenerated it or any production registration bytes moved.
    Invoke-NativeStep 'candidate-dev-registration-readback' 'py' @(
        '-3.12', $devRegistrantCorrection, '--mobile-root', $mobileRoot,
        '--expected-repo', $repo, '--mode', 'verify-clean',
        '--expected-sha256', $registrantReceipt.after_sha256
    ) 'dev-registration-readback.json'
    Invoke-NativeStep 'frozen-input-after-build' 'py' @('-3.12', $freezeHelper, 'verify', '--repo', $repo, '--manifest', $manifestPath, '--expected-sha256', $ExpectedMobileManifestSha256) 'frozen-after-build.json'

    $built = Join-Path $shortRepo 'apps\mobile_flutter\build\app\outputs\flutter-apk\app-standard-release.apk'
    Require-File $built 'Flutter source APK'
    $source = Join-Path $dest 'source.apk'
    Copy-Item -LiteralPath $built -Destination $source -ErrorAction Stop
    Require-File $source 'Copied source APK'
    Invoke-NativeStep 'source-release-payload' 'py' @('-3.12', (Join-Path $shortRepo 'scripts\verify_android_release.py'), $source) 'source-gate.json'
    Invoke-NativeStep 'source-flutter-assets' 'py' @('-3.12', $bundleVerifier, $source, '--mobile-root', (Join-Path $shortRepo 'apps\mobile_flutter')) 'source-flutter-assets.json'
    Invoke-NativeStep 'source-aapt-badging' $aapt @('dump', 'badging', $source) 'source-identity.log'
    Assert-ReleaseIdentity (Join-Path $dest 'source-identity.log')
    Invoke-NativeStep 'source-aapt-resources' $aapt @('dump', 'resources', $source) 'source-resources.log'
    Invoke-NativeStep 'source-aapt-manifest' $aapt @('dump', 'xmltree', $source, 'AndroidManifest.xml') 'original-manifest.txt'

    $decoded = Join-Path $dest 'decoded'
    $framework = Join-Path $dest 'framework'
    $unsigned = Join-Path $dest 'unsigned.apk'
    $aligned = Join-Path $dest 'aligned.apk'
    $final = Join-Path $dest 'final.apk'
    Invoke-NativeStep 'apktool-decode' $java @('-Xmx4G', '-jar', $apktool, 'd', $source, '-o', $decoded, '-p', $framework) 'decode.log'
    Invoke-NativeStep 'apktool-rebuild' $java @('-Xmx4G', '-jar', $apktool, 'b', $decoded, '-p', $framework, '-o', $unsigned) 'rebuild.log'
    Invoke-NativeStep 'zipalign' $zipalign @('-P', '16', '-f', '4', $unsigned, $aligned) 'zipalign.log'
    Assert-StableSignerPresent
    Invoke-NativeStep 'fixed-identity-sign' 'pwsh.exe' @('-NoProfile', '-File', $signer, '-InputApk', $aligned, '-OutputApk', $final, '-Apksigner', $apksigner, '-Execute') 'signature.log'
    Require-File $final 'Signed final APK'

    Invoke-NativeStep 'apksigner-verify' $apksigner @('verify', '--verbose', '--print-certs', $final) 'apksigner-verify.log'
    $signature = Get-Content -LiteralPath (Join-Path $dest 'apksigner-verify.log') -Raw -Encoding utf8
    if ($signature -notmatch "(?m)^Signer #1 certificate SHA-256 digest: $expectedCertificate\s*$" -or
        $signature -notmatch '(?m)^Verified using v2 scheme .*: true\s*$' -or
        $signature -notmatch '(?m)^Verified using v3 scheme .*: true\s*$' -or
        $signature -notmatch '(?m)^Number of signers: 1\s*$') {
        throw 'Final APK signer or signature scheme mismatch'
    }
    Invoke-NativeStep 'zipalign-signed-check' $zipalign @('-c', '-P', '16', '4', $final) 'zipalign-check.log'
    Invoke-NativeStep 'final-release-payload' 'py' @('-3.12', (Join-Path $shortRepo 'scripts\verify_android_release.py'), $final) 'final-gate.json'
    Invoke-NativeStep 'final-flutter-assets' 'py' @('-3.12', $bundleVerifier, $final, '--mobile-root', (Join-Path $shortRepo 'apps\mobile_flutter')) 'final-flutter-assets.json'
    Invoke-NativeStep 'final-aapt-badging' $aapt @('dump', 'badging', $final) 'identity.log'
    Assert-ReleaseIdentity (Join-Path $dest 'identity.log')
    Invoke-NativeStep 'final-aapt-resources' $aapt @('dump', 'resources', $final) 'final-resources.log'
    Invoke-NativeStep 'final-aapt-manifest' $aapt @('dump', 'xmltree', $final, 'AndroidManifest.xml') 'rebuilt-manifest.txt'
    Invoke-NativeStep 'independent-final-decode' $java @('-Xmx4G', '-jar', $apktool, 'd', $final, '-o', (Join-Path $dest 'verified-decoded'), '-p', (Join-Path $dest 'verify-framework')) 'verify-decode.log'
    Invoke-NativeStep 'final-lock-boundary' 'py' @('-3.12', $lockVerifier, '--repo', $repo, '--baseline', $lockBaseline, '--expected-baseline-sha256', $lockBaselineSha, '--decoded', (Join-Path $dest 'verified-decoded'), '--manifest', (Join-Path $dest 'rebuilt-manifest.txt')) 'lock-boundary.json'
    Invoke-NativeStep 'rebuild-semantic-check' 'py' @('-3.12', $semanticVerifier, $dest) 'rebuild-verification.json'
    Invoke-NativeStep 'frozen-input-after-verification' 'py' @('-3.12', $freezeHelper, 'verify', '--repo', $repo, '--manifest', $manifestPath, '--expected-sha256', $ExpectedMobileManifestSha256) 'frozen-after-verification.json'

    $metadata = [ordered]@{
        version = $version
        build = $build
        mode = 'standard-arm64-release'
        icon_tree_shaking = $false
        dart_obfuscation = $false
        r8_minification = $false
        source_commit = $frozenInput.source_commit
        mobile_manifest_sha256 = $frozenInput.manifest_sha256
        mobile_file_count = $frozenInput.file_count
        isolated_build_cache = $expectedBuildRoot
        pubspec_lock_sha256 = (Get-FileHash -LiteralPath (Join-Path $mobileRoot 'pubspec.lock') -Algorithm SHA256).Hash.ToLowerInvariant()
        source_apk_sha256 = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
        final_apk_sha256 = (Get-FileHash -LiteralPath $final -Algorithm SHA256).Hash.ToLowerInvariant()
        final_apk_bytes = (Get-Item -LiteralPath $final).Length
        signer_sha256 = $expectedCertificate
        dart_defines = $defines
        production_android_build_at_preflight = $ConfirmedProductionAndroidBuild
        production_ios_build_at_preflight = $ConfirmedProductionIosBuild
        production_checked_at_utc = $ProductionCheckedAtUtc.ToUniversalTime().ToString('o')
        build_driver_sha256 = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
        freeze_helper_sha256 = (Get-FileHash -LiteralPath $freezeHelper -Algorithm SHA256).Hash.ToLowerInvariant()
        complete_bundle_verifier_sha256 = (Get-FileHash -LiteralPath $bundleVerifier -Algorithm SHA256).Hash.ToLowerInvariant()
        dev_registrant_helper_sha256 = (Get-FileHash -LiteralPath $devRegistrantCorrection -Algorithm SHA256).Hash.ToLowerInvariant()
        dev_registrant_after_sha256 = $registrantReceipt.after_sha256
        lock_closure_baseline_sha256 = $lockBaselineSha
        lock_closure_verifier_sha256 = (Get-FileHash -LiteralPath $lockVerifier -Algorithm SHA256).Hash.ToLowerInvariant()
        signer_script_sha256 = (Get-FileHash -LiteralPath $signer -Algorithm SHA256).Hash.ToLowerInvariant()
        apktool_sha256 = $pinnedTools.apktool_sha256
        semantic_verifier_sha256 = (Get-FileHash -LiteralPath $semanticVerifier -Algorithm SHA256).Hash.ToLowerInvariant()
        finished_at = (Get-Date).ToString('o')
    }
    [IO.File]::WriteAllText((Join-Path $dest 'artifact.json'), ($metadata | ConvertTo-Json -Depth 4), $utf8)
    Write-Output "BUILD_2215_ARM64_PASS $([IO.Path]::GetFullPath((Join-Path $output $RunId)))"
} finally {
    $env:GRADLE_OPTS = $originalGradleOpts
    $env:ORG_GRADLE_PROJECT_chatflowParallelDebug = $originalParallelDebug
    $env:PUB_HOSTED_URL = $originalPubHost
    $env:JAVA_HOME = $originalJavaHome
    $env:Path = $originalPath
    if ($artifactMappingOwned -and (Get-SubstTarget $ArtifactDrive) -eq $output) {
        & subst.exe "${ArtifactDrive}:" /D | Out-Null
    }
    if ($sourceMappingOwned -and (Get-SubstTarget $SourceDrive) -eq $repo) {
        & subst.exe "${SourceDrive}:" /D | Out-Null
    }
}
