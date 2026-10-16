from pathlib import Path
import hashlib

ROOT = Path(__file__).resolve().parents[5]
HERE = Path(__file__).resolve().parent
old = ROOT / 'docs/verification/artifacts/2026-10-12/android2215-release-candidate'
freeze = (old/'freeze_mobile_input.py').read_text(encoding='utf-8').replace('0.4.46','0.4.47').replace('2215','2216')
(HERE/'freeze_mobile_input.py').write_text(freeze,encoding='utf-8')
s = (ROOT/'docs/verification/artifacts/2026-10-16/super-emoji-autoplay/build-debug.ps1').read_text(encoding='utf-8')
s = s.replace("$env:ORG_GRADLE_PROJECT_chatflowParallelDebug='true'", "$env:ORG_GRADLE_PROJECT_chatflowParallelDebug='false'")
s = s.replace('-Dorg.gradle.project.chatflowParallelDebug=true','-Dorg.gradle.project.chatflowParallelDebug=false')
s = s.replace('super-emoji-autoplay/', 'android2216-release/')
s = s.replace("'--debug'", "'--release','--no-tree-shake-icons'").replace("'android-x64'", "'android-arm64'")
s = s.replace('app-standard-debug.apk','app-standard-release.apk')
s = s.replace("com\\.liuhetong\\.mobile\\.debug", "com\\.liuhetong\\.mobile").replace("native-code: 'x86_64'", "native-code: 'arm64-v8a'")
s = s.replace("$identity -notmatch 'application-debuggable'", "$identity -match 'application-debuggable'")
s = s.replace("package='com.liuhetong.mobile.debug';abi='x86_64'", "package='com.liuhetong.mobile';abi='arm64-v8a'")
s = s.replace('Named Debug entry point', 'ARM64 Release entry point').replace('DEBUG_BUILD_PASS', 'RELEASE_BUILD_PASS')
s = s.replace(" Step 'source-build'", " Step 'source-build'")
needle="  Step 'source-build'"
before="""  Step 'freeze-input' 'py' @('-3.12',(Join-Path $PSScriptRoot 'freeze_mobile_input.py'),'create','--repo',$repoPath,'--manifest',(Join-Path $dest 'mobile-inputs.json'))
  Step 'registrant-correction' 'py' @('-3.12',(Join-Path $repoPath 'docs/verification/artifacts/2026-10-12/android2215-release-candidate/strip_dev_plugin_registrant.py'),'--mobile-root',(Join-Path $repoPath 'apps/mobile_flutter'),'--expected-repo',$repoPath,'--mode','ensure-clean')
"""
s=s.replace(needle,before+needle)
s=s.replace(" Step 'original-manifest'", " Step 'source-release-payload' 'py' @('-3.12',(Join-Path $repoPath 'scripts/verify_android_release.py'),$source)\n Step 'source-assets' 'py' @('-3.12',(Join-Path $repoPath 'docs/verification/artifacts/2026-10-12/android2215-release-candidate/verify_android_flutter_assets.py'),$source,'--mobile-root',(Join-Path $repoPath 'apps/mobile_flutter'))\n Step 'original-manifest'")
s=s.replace(" Step 'rebuilt-manifest'", " Step 'final-release-payload' 'py' @('-3.12',(Join-Path $repoPath 'scripts/verify_android_release.py'),$final)\n Step 'final-assets' 'py' @('-3.12',(Join-Path $repoPath 'docs/verification/artifacts/2026-10-12/android2215-release-candidate/verify_android_flutter_assets.py'),$final,'--mobile-root',(Join-Path $repoPath 'apps/mobile_flutter'))\n Step 'frozen-after' 'py' @('-3.12',(Join-Path $PSScriptRoot 'freeze_mobile_input.py'),'verify','--repo',$repoPath,'--manifest',(Join-Path $dest 'mobile-inputs.json'),'--expected-sha256',(Get-FileHash -LiteralPath (Join-Path $dest 'mobile-inputs.json') -Algorithm SHA256).Hash.ToLowerInvariant())\n Step 'rebuilt-manifest'")
s=s.replace("[ordered]@{status='PASS'", "[ordered]@{mode='standard-arm64-release';build=2216;mobile_manifest_sha256=(Get-FileHash -LiteralPath (Join-Path $dest 'mobile-inputs.json') -Algorithm SHA256).Hash.ToLowerInvariant();pubspec_lock_sha256=(Get-FileHash -LiteralPath (Join-Path $repoPath 'apps/mobile_flutter/pubspec.lock') -Algorithm SHA256).Hash.ToLowerInvariant();status='PASS'")
s=s.replace("version='0.4.47+2216'", "version='0.4.47'")
s=s.replace("$started=[DateTimeOffset]", "[IO.File]::WriteAllText((Join-Path $dest 'steps.tsv'),\"step`texit_code`n\",$taskUtf8)\n$started=[DateTimeOffset]")
(HERE/'build-release.ps1').write_text(s,encoding='utf-8')
print('Builder prepared; no build or publication executed')
