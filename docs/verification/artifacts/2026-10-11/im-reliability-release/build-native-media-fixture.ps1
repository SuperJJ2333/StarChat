param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string]$RunName)
$ErrorActionPreference='Stop'
$taskUtf8=[System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding=$taskUtf8
[Console]::OutputEncoding=$taskUtf8
$OutputEncoding=$taskUtf8
$env:PYTHONUTF8='1'
$env:PYTHONIOENCODING='utf-8'
$env:PUB_HOSTED_URL='https://pub.dev'
$env:JAVA_HOME='C:/Program Files/Microsoft/jdk-17.0.20.8-hotspot'
$env:Path=$env:JAVA_HOME+'/bin;'+$env:Path
$env:ORG_GRADLE_PROJECT_chatflowParallelDebug='true'
$env:GRADLE_OPTS='-Dorg.gradle.workers.max=2 -Dorg.gradle.project.chatflowParallelDebug=true'
$repoPath=[IO.Path]::GetFullPath($Repo)
if($RunName -notmatch '^[a-zA-Z0-9-]+$'){throw 'Invalid run name'}
$dest=Join-Path $repoPath ('docs/verification/artifacts/2026-10-11/im-reliability-release/native-'+$RunName)
New-Item -ItemType Directory -Path $dest -ErrorAction Stop | Out-Null
$flutter='C:/src/flutter/bin/flutter.bat'
$toolsRoot='C:/Users/Administrator/AppData/Local/Android/Sdk/build-tools/36.0.0'
$adb='C:/Users/Administrator/AppData/Local/Android/Sdk/platform-tools/adb.exe'
$apktool='D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-09-30/main-wallet-search/android-release/apktool_2.12.1.jar'
$signer='D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-09-30/main-wallet-search/android-release/sign-existing-identity.ps1'
$verifier='D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-09-27/android-public-diagnostics-update/android-release/verify_rebuild.py'
$signing=Join-Path $env:USERPROFILE '.chatflow-signing/diagnostic-20260905'
foreach($item in @($apktool,$signer,$verifier,(Join-Path $signing 'diagnostic.p12'),(Join-Path $signing 'password.dpapi'))){if(!(Test-Path -LiteralPath $item -PathType Leaf)){throw 'Required fixed tool or signer missing'}}
$device='emulator-5558'
$package='com.liuhetong.mobile.debug'
function Assert-EmptyFixturePackage {
  $state=(@(& $adb -s $device get-state) -join '').Trim()
  if($LASTEXITCODE-ne 0 -or $state-ne 'device'){throw 'Fixture device unavailable'}
  $existing=@(& $adb -s $device shell pm list packages -u $package)
  if($LASTEXITCODE-ne 0 -or ($existing | Where-Object {$_.Trim()-eq "package:$package"})){throw 'Fixture package already exists or package inspection failed; never replace existing data'}
}
Assert-EmptyFixturePackage
$mapping=@(& subst.exe)
if($LASTEXITCODE -ne 0 -or ($mapping -match '^W:') -or (Test-Path -LiteralPath 'W:/')){throw 'W drive must be unoccupied'}
$started=Get-Date -Format o
$installed=$false
$ownedMapping=$false
function Step([string]$Name,[string]$Command,[string[]]$Arguments){
  $log=Join-Path $dest ($Name+'.log')
  & $Command @Arguments *> $log
  $result=$LASTEXITCODE
  [IO.File]::AppendAllText((Join-Path $dest 'steps.tsv'),"$Name`t$result`n",$taskUtf8)
  if($result-ne 0){throw "$Name failed; inspect $log"}
}
try {
  & subst.exe W: $repoPath
  if($LASTEXITCODE-ne 0){throw 'Cannot create owned source mapping'}
  $ownedMapping=$true
  Push-Location -LiteralPath 'W:/apps/mobile_flutter'
  try {
    Step 'source-build' $flutter @('build','apk','--debug','--no-pub','--flavor','standard','--target-platform','android-x64','-t','integration_test/reliability_media_native_test.dart')
  } finally {Pop-Location}
  Copy-Item -LiteralPath (Join-Path $repoPath 'apps/mobile_flutter/build/app/outputs/flutter-apk/app-standard-debug.apk') -Destination (Join-Path $dest 'source.apk')
  $source=Join-Path $dest 'source.apk'
  $final=Join-Path $dest 'final.apk'
  Step 'original-manifest' (Join-Path $toolsRoot 'aapt.exe') @('dump','xmltree',$source,'AndroidManifest.xml')
  Copy-Item -LiteralPath (Join-Path $dest 'original-manifest.log') -Destination (Join-Path $dest 'original-manifest.txt')
  Step 'decode' 'java' @('-Xmx4G','-jar',$apktool,'d',$source,'-o',(Join-Path $dest 'decoded'),'-p',(Join-Path $dest 'framework'))
  Step 'rebuild' 'java' @('-Xmx4G','-jar',$apktool,'b',(Join-Path $dest 'decoded'),'-p',(Join-Path $dest 'framework'),'-o',(Join-Path $dest 'unsigned.apk'))
  Step 'align' (Join-Path $toolsRoot 'zipalign.exe') @('-P','16','-f','4',(Join-Path $dest 'unsigned.apk'),(Join-Path $dest 'aligned.apk'))
  Step 'sign' 'pwsh.exe' @('-NoProfile','-File',$signer,'-InputApk',(Join-Path $dest 'aligned.apk'),'-OutputApk',$final)
  Step 'signature' (Join-Path $toolsRoot 'apksigner.bat') @('verify','--verbose','--print-certs',$final)
  $signature=Get-Content -LiteralPath (Join-Path $dest 'signature.log') -Raw -Encoding utf8
  if($signature -notmatch 'Signer #1 certificate SHA-256 digest: 75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff'){throw 'Signer mismatch'}
  Step 'alignment' (Join-Path $toolsRoot 'zipalign.exe') @('-c','-P','16','4',$final)
  Step 'identity' (Join-Path $toolsRoot 'aapt.exe') @('dump','badging',$final)
  $identity=Get-Content -LiteralPath (Join-Path $dest 'identity.log') -Raw -Encoding utf8
  if($identity -notmatch "package: name='com\.liuhetong\.mobile\.debug' versionCode='2214'" -or $identity -notmatch "native-code: 'x86_64'" -or $identity -notmatch 'application-debuggable'){throw 'Unexpected synthetic fixture identity'}
  Step 'rebuilt-manifest' (Join-Path $toolsRoot 'aapt.exe') @('dump','xmltree',$final,'AndroidManifest.xml')
  Copy-Item -LiteralPath (Join-Path $dest 'rebuilt-manifest.log') -Destination (Join-Path $dest 'rebuilt-manifest.txt')
  Step 'verify-decode' 'java' @('-Xmx4G','-jar',$apktool,'d',$final,'-o',(Join-Path $dest 'verified-decoded'),'-p',(Join-Path $dest 'verify-framework'))
  Step 'rebuild-verification' 'D:/python/python.exe' @($verifier,$dest)
  $sha=(Get-FileHash -LiteralPath $final -Algorithm SHA256).Hash.ToLowerInvariant()
  Assert-EmptyFixturePackage
  Step 'install' 'py' @('-3.12',(Join-Path $PSScriptRoot 'bounded_native_adb_install.py'),$final)
  $installed=$true
  Push-Location -LiteralPath 'W:/apps/mobile_flutter'
  try {
    Step 'native-drive' $flutter @('drive','--no-pub','--debug','--flavor','standard','--use-application-binary',$final,'--driver','integration_test/permission_driver.dart','-t','integration_test/reliability_media_native_test.dart','-d',$device,'--timeout','180')
  } finally {Pop-Location}
  @{source_commit=(& git -C $repoPath rev-parse HEAD);started=$started;ended=(Get-Date -Format o);device=$device;package=$package;artifact_sha256=$sha;scope='synthetic native storage and SQLite persistence, not device performance or OEM behavior';result='PASS'} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dest 'receipt.json') -Encoding utf8NoBOM
} finally {
  try {
    if($installed){
      $path=(@(& $adb -s $device shell pm path $package) -join '').Trim().Replace('package:','')
      if($path -and $path.StartsWith('/data/app/')){
        $current=(@(& $adb -s $device shell sha256sum $path) -join '').Split(' ')[0]
        if($LASTEXITCODE-eq 0 -and $current-eq $sha){Step 'owned-fixture-remove' $adb @('-s',$device,'uninstall',$package)}
        else {throw 'Installed fixture identity changed; do not remove'}
      }
    }
  } finally {
    if($ownedMapping){
      $actual=@(@(& subst.exe) | Where-Object {$_ -match '^W:\\: => '})
      if($actual.Count-eq 1 -and $actual[0] -match '^W:\\: => (.+)$'){
        if($Matches[1].TrimEnd('\')-eq $repoPath.TrimEnd('\')){& subst.exe W: /D}
      }
    }
  }
}
