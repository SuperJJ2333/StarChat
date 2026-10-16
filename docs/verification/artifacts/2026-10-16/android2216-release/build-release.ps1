param([Parameter(Mandatory)][string]$Repo,[Parameter(Mandatory)][string]$RunName,[string]$Target="lib/main.dart")
$ErrorActionPreference='Stop'
$taskUtf8=[System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding=$taskUtf8
[Console]::OutputEncoding=$taskUtf8
$OutputEncoding=$taskUtf8
$env:PYTHONUTF8='1'
$env:PYTHONIOENCODING='utf-8'
$env:PUB_HOSTED_URL='https://pub.dev'
$env:FLUTTER_STORAGE_BASE_URL='https://storage.googleapis.com'
$env:JAVA_HOME='C:/Program Files/Microsoft/jdk-17.0.20.8-hotspot'
$env:Path=$env:JAVA_HOME+'/bin;'+$env:Path
$env:ORG_GRADLE_PROJECT_chatflowParallelDebug='false'
$env:GRADLE_OPTS='-Dorg.gradle.workers.max=2 -Dorg.gradle.jvmargs=-Xmx3g -Dorg.gradle.project.chatflowParallelDebug=false'
$repoPath=[IO.Path]::GetFullPath($Repo)
if($RunName -notmatch '^[a-zA-Z0-9-]+$'){throw 'Invalid run name'}
$dest=Join-Path $repoPath ('docs/verification/artifacts/2026-10-16/android2216-release/'+$RunName)
if(Test-Path -LiteralPath $dest){throw 'Run output exists; inspect before retry'}
New-Item -ItemType Directory -Path $dest | Out-Null
$flutter='C:/src/flutter/bin/flutter.bat'
$tools='C:/Users/Administrator/AppData/Local/Android/Sdk/build-tools/36.0.0'
$apktool='C:/Users/Administrator/.codex/worktrees/im-reliability/StarChat/docs/verification/artifacts/2026-10-12/android2214-media-regression/tools/apktool_2.12.1.jar'
$signer='C:/Users/Administrator/.codex/worktrees/im-reliability/StarChat/docs/verification/artifacts/2026-10-12/media-debug-packaging-tools/sign-existing-identity.ps1'
$verifier='C:/Users/Administrator/.codex/worktrees/im-reliability/StarChat/docs/verification/artifacts/2026-10-12/media-debug-packaging-tools/verify_rebuild.py'
foreach($item in @($apktool,$signer,$verifier,(Join-Path $env:USERPROFILE '.chatflow-signing/diagnostic-20260905/diagnostic.p12'),(Join-Path $env:USERPROFILE '.chatflow-signing/diagnostic-20260905/password.dpapi'))){if(!(Test-Path -LiteralPath $item -PathType Leaf)){throw 'Fixed tool/signing artifact unavailable'}}
if((@(& subst.exe) -match '^W:') -or (Test-Path -LiteralPath 'W:/')){throw 'W drive occupied'}
if($Target -notmatch '^(lib/main|integration_test/[a-z0-9_]+)\.dart$'){throw 'Unexpected debug target'}
[IO.File]::WriteAllText((Join-Path $dest 'steps.tsv'),"step`texit_code`n",$taskUtf8)
$started=[DateTimeOffset]::UtcNow.ToString('o')
$commit=(@(& git -C $repoPath rev-parse HEAD) -join '').Trim()
$mobileDrift=@(& git -C $repoPath status --porcelain --untracked-files=all -- apps/mobile_flutter)
if($LASTEXITCODE-ne 0 -or $mobileDrift.Count-ne 0){throw 'Freeze and commit mobile source before candidate build'}
$version=Get-Content -LiteralPath (Join-Path $repoPath 'apps/mobile_flutter/pubspec.yaml') -Raw -Encoding utf8
if($version -notmatch '(?m)^version: 0\.4\.47\+2216\s*$'){throw 'Unexpected candidate source version'}
$owned=$false
function Step([string]$Name,[string]$Command,[string[]]$Arguments){
 & $Command @Arguments *> (Join-Path $dest ($Name+'.log'))
 $result=$LASTEXITCODE
 [IO.File]::AppendAllText((Join-Path $dest 'steps.tsv'),"$Name`t$result`n",$taskUtf8)
 if($result-ne 0){throw "$Name failed; inspect named run log"}
}
try {
 & subst.exe W: $repoPath
 if($LASTEXITCODE-ne 0){throw 'Owned source mapping failed'}
 $owned=$true
 Push-Location -LiteralPath 'W:/apps/mobile_flutter'
 try {
  Step 'pub-get' $flutter @('pub','get','--offline','--enforce-lockfile')
  Step 'freeze-input' 'py' @('-3.12',(Join-Path $PSScriptRoot 'freeze_mobile_input.py'),'create','--repo',$repoPath,'--manifest',(Join-Path $dest 'mobile-inputs.json'))
  Step 'registrant-correction' 'py' @('-3.12',(Join-Path $repoPath 'docs/verification/artifacts/2026-10-12/android2215-release-candidate/strip_dev_plugin_registrant.py'),'--mobile-root',(Join-Path $repoPath 'apps/mobile_flutter'),'--expected-repo',$repoPath,'--mode','ensure-clean')
  Step 'source-build' $flutter @('build','apk','--release','--no-tree-shake-icons','--no-pub','--flavor','standard','--target-platform','android-arm64','-t',$Target,'--dart-define=LIUHETONG_MATRIX_HOMESERVER=https://liuhetong888.com','--dart-define=LIUHETONG_BUSINESS_API_URL=https://liuhetong888.com','--dart-define=LIUHETONG_GETUI_URL=https://liuhetong888.com','--dart-define=CHATFLOW_PERFORMANCE_METRICS=true')
 } finally {Pop-Location}
 Copy-Item -LiteralPath (Join-Path $repoPath 'apps/mobile_flutter/build/app/outputs/flutter-apk/app-standard-release.apk') -Destination (Join-Path $dest 'source.apk')
 $source=Join-Path $dest 'source.apk';$final=Join-Path $dest 'final.apk'
 Step 'source-release-payload' 'py' @('-3.12',(Join-Path $repoPath 'scripts/verify_android_release.py'),$source)
 Step 'source-assets' 'py' @('-3.12',(Join-Path $repoPath 'docs/verification/artifacts/2026-10-12/android2215-release-candidate/verify_android_flutter_assets.py'),$source,'--mobile-root',(Join-Path $repoPath 'apps/mobile_flutter'))
 Step 'original-manifest' (Join-Path $tools 'aapt.exe') @('dump','xmltree',$source,'AndroidManifest.xml')
 Copy-Item -LiteralPath (Join-Path $dest 'original-manifest.log') -Destination (Join-Path $dest 'original-manifest.txt')
 Step 'decode' 'java' @('-Xmx4G','-jar',$apktool,'d',$source,'-o',(Join-Path $dest 'decoded'),'-p',(Join-Path $dest 'framework'))
 Step 'rebuild' 'java' @('-Xmx4G','-jar',$apktool,'b',(Join-Path $dest 'decoded'),'-p',(Join-Path $dest 'framework'),'-o',(Join-Path $dest 'unsigned.apk'))
 Step 'align' (Join-Path $tools 'zipalign.exe') @('-P','16','-f','4',(Join-Path $dest 'unsigned.apk'),(Join-Path $dest 'aligned.apk'))
 Step 'sign' 'pwsh.exe' @('-NoProfile','-File',$signer,'-InputApk',(Join-Path $dest 'aligned.apk'),'-OutputApk',$final,'-Apksigner',(Join-Path $tools 'apksigner.bat'),'-Execute')
 Step 'signature' (Join-Path $tools 'apksigner.bat') @('verify','--verbose','--print-certs',$final)
 if((Get-Content -LiteralPath (Join-Path $dest 'signature.log') -Raw -Encoding utf8) -notmatch 'Signer #1 certificate SHA-256 digest: 75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff'){throw 'Fixed signer mismatch'}
 Step 'alignment' (Join-Path $tools 'zipalign.exe') @('-c','-P','16','4',$final)
 Step 'identity' (Join-Path $tools 'aapt.exe') @('dump','badging',$final)
 $identity=Get-Content -LiteralPath (Join-Path $dest 'identity.log') -Raw -Encoding utf8
 if($identity -notmatch "package: name='com\.liuhetong\.mobile'" -or $identity -notmatch "native-code: 'arm64-v8a'" -or $identity -match 'application-debuggable'){throw 'Unexpected debug identity'}
 if($identity -notmatch "versionCode='2216'" -or $identity -notmatch "versionName='0\.4\.47'"){throw 'Unexpected candidate APK version'}
 Step 'final-release-payload' 'py' @('-3.12',(Join-Path $repoPath 'scripts/verify_android_release.py'),$final)
 Step 'final-assets' 'py' @('-3.12',(Join-Path $repoPath 'docs/verification/artifacts/2026-10-12/android2215-release-candidate/verify_android_flutter_assets.py'),$final,'--mobile-root',(Join-Path $repoPath 'apps/mobile_flutter'))
 Step 'frozen-after' 'py' @('-3.12',(Join-Path $PSScriptRoot 'freeze_mobile_input.py'),'verify','--repo',$repoPath,'--manifest',(Join-Path $dest 'mobile-inputs.json'),'--expected-sha256',(Get-FileHash -LiteralPath (Join-Path $dest 'mobile-inputs.json') -Algorithm SHA256).Hash.ToLowerInvariant())
 Step 'rebuilt-manifest' (Join-Path $tools 'aapt.exe') @('dump','xmltree',$final,'AndroidManifest.xml')
 Copy-Item -LiteralPath (Join-Path $dest 'rebuilt-manifest.log') -Destination (Join-Path $dest 'rebuilt-manifest.txt')
 Step 'verify-decode' 'java' @('-Xmx4G','-jar',$apktool,'d',$final,'-o',(Join-Path $dest 'verified-decoded'),'-p',(Join-Path $dest 'verify-framework'))
 Step 'rebuild-verification' 'py' @('-3.12',$verifier,$dest)
 [ordered]@{mode='standard-arm64-release';build=2216;mobile_manifest_sha256=(Get-FileHash -LiteralPath (Join-Path $dest 'mobile-inputs.json') -Algorithm SHA256).Hash.ToLowerInvariant();pubspec_lock_sha256=(Get-FileHash -LiteralPath (Join-Path $repoPath 'apps/mobile_flutter/pubspec.lock') -Algorithm SHA256).Hash.ToLowerInvariant();status='PASS';source_commit=$commit;started_utc=$started;completed_utc=[DateTimeOffset]::UtcNow.ToString('o');target=$Target;version='0.4.47';package='com.liuhetong.mobile';abi='arm64-v8a';signer_sha256='75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff';final_apk_sha256=(Get-FileHash -LiteralPath $final -Algorithm SHA256).Hash.ToLowerInvariant();final_apk_bytes=(Get-Item -LiteralPath $final).Length;scope='ARM64 Release entry point; source build/rebuild/sign/semantic checks only; installation and native runtime are separate.'} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dest 'receipt.json') -Encoding utf8NoBOM
 Write-Output "RELEASE_BUILD_PASS $RunName"
} finally {
 if($owned){
  $actual=@(@(& subst.exe) | Where-Object {$_ -match '^W:\\: => '})
  if($actual.Count-eq 1 -and $actual[0] -match '^W:\\: => (.+)$' -and $Matches[1].TrimEnd('\')-eq $repoPath.TrimEnd('\')){& subst.exe W: /D}
 }
}
