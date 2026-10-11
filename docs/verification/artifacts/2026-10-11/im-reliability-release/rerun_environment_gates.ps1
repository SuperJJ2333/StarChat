param([ValidateSet('Recovery','Moments')][string]$Gate)
$ErrorActionPreference='Stop'
$taskUtf8=[System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding=$taskUtf8
[Console]::OutputEncoding=$taskUtf8
$OutputEncoding=$taskUtf8
$env:PYTHONUTF8='1'; $env:PYTHONIOENCODING='utf-8'
$env:PUB_HOSTED_URL='https://pub.dev'
$repo='C:\Users\Administrator\.codex\worktrees\im-reliability\StarChat'
$artifact=Join-Path $repo 'docs/verification/artifacts/2026-10-11/im-reliability-release'
$env:PATH='C:/Users/Administrator/.codex/worktrees/search-camera-history-20261003/StarChat/docs/verification/artifacts/2026-10-03/search-camera-history/task-3a-windows-olm;C:/Users/Administrator/.codex/worktrees/search-camera-history-20261003/StarChat/docs/verification/artifacts/2026-10-03/search-camera-history/task-3b-sqlcipher-build;'+$env:PATH
if(Test-Path -LiteralPath 'W:\') { throw 'W already exists; do not replace another mapping' }
$started=[DateTimeOffset]::UtcNow.ToString('o')
$code=1
try {
  & subst.exe W: $repo
  if($LASTEXITCODE -ne 0) { throw 'subst failed' }
  foreach($relative in @('docs/verification/artifacts/2026-10-04/history-anchor-media-ios','docs/verification/artifacts/2026-10-03/search-camera-history')) {
    [System.IO.Directory]::CreateDirectory((Join-Path $repo $relative)) | Out-Null
  }
  Set-Location -LiteralPath 'W:/apps/mobile_flutter'
  $files=if($Gate -eq 'Recovery') {
    @('test/features/matrix/historical_encrypted_event_resolution_test.dart','test/features/matrix/retained_recovery_archive_test.dart','test/features/matrix/retained_recovery_identity_test.dart')
  } else {
    @('test/features/moments/moment_publish_legacy_ready_test.dart','test/features/moments/moment_video_test.dart')
  }
  $log=Join-Path $artifact ('environment-'+$Gate.ToLowerInvariant()+'.log')
  & C:/src/flutter/bin/flutter.bat test --no-pub --reporter expanded --timeout 90s @files *> $log
  $code=$LASTEXITCODE
  Get-Content -LiteralPath $log -Tail 12 -Encoding utf8
} finally {
  Set-Location -LiteralPath $repo
  $mapping=(& subst.exe) -join "`n"
  if($mapping -match [regex]::Escape('W:\: => '+$repo)) { & subst.exe W: /D }
  @{gate=$Gate;started_at_utc=$started;ended_at_utc=[DateTimeOffset]::UtcNow.ToString('o');exit_code=$code;source_head='9902d35079e9cb051125808a251ae479b06893cb';environment_changes='empty fixture parents and owned W alias; no product edits'} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $artifact ('environment-'+$Gate.ToLowerInvariant()+'-receipt.json')) -Encoding utf8NoBOM
}
exit $code
