param([ValidateSet('Flutter','Analyze','Boundaries','Policy')][string]$Gate)
$ErrorActionPreference='Stop'
[Console]::InputEncoding=[System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding=[System.Text.UTF8Encoding]::new($false)
$OutputEncoding=[System.Text.UTF8Encoding]::new($false)
$env:PYTHONUTF8='1'; $env:PYTHONIOENCODING='utf-8'
$env:PUB_HOSTED_URL='https://pub.dev'
$repo='C:/Users/Administrator/.codex/worktrees/im-reliability/StarChat'
$env:PATH='C:/Users/Administrator/.codex/worktrees/search-camera-history-20261003/StarChat/docs/verification/artifacts/2026-10-03/search-camera-history/task-3a-windows-olm;C:/Users/Administrator/.codex/worktrees/search-camera-history-20261003/StarChat/docs/verification/artifacts/2026-10-03/search-camera-history/task-3b-sqlcipher-build;'+$env:PATH
$started=[DateTimeOffset]::UtcNow.ToString('o')
$log=Join-Path $PSScriptRoot ($Gate.ToLowerInvariant()+'-final.log')
if($Gate -eq 'Flutter') {
 Set-Location -LiteralPath 'C:/Users/Administrator/.codex/worktrees/im-reliability/StarChat/apps/mobile_flutter'
 & C:/src/flutter/bin/flutter.bat test --no-pub --reporter expanded *> $log
 $code=$LASTEXITCODE
} elseif($Gate -eq 'Analyze') {
 Set-Location -LiteralPath 'C:/Users/Administrator/.codex/worktrees/im-reliability/StarChat/apps/mobile_flutter'
 & C:/src/flutter/bin/flutter.bat analyze --no-pub *> $log
 $code=$LASTEXITCODE
} elseif($Gate -eq 'Boundaries') {
 Set-Location -LiteralPath $repo
 & py -3.12 -m pytest -q -p no:cacheprovider tests/mobile tests/test_android_delta.py *> $log
 $code=$LASTEXITCODE
} else {
 Set-Location -LiteralPath $repo
 $code=0
 foreach($file in @('tests/repository/Test-RepositoryPolicy.ps1','tests/repository/Test-DeploymentPolicy.ps1','tests/powershell/Test-TemplateTools.ps1')) {
  & pwsh.exe -NoProfile -File $file *>> $log
  if($LASTEXITCODE -ne 0) { $code=$LASTEXITCODE; break }
 }
}
@{gate=$Gate;started_at_utc=$started;ended_at_utc=[DateTimeOffset]::UtcNow.ToString('o');exit_code=$code;log=$log} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot ($Gate.ToLowerInvariant()+'-receipt.json')) -Encoding utf8NoBOM
Get-Content -LiteralPath $log -Tail 8 -Encoding utf8
exit $code
