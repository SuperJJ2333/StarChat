param(
  [Parameter(Mandatory)][ValidateSet('Flutter','Analyze','Boundaries','Policy')][string]$Gate,
  [Parameter(Mandatory)][string]$Repo,
  [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9-]+$')][string]$RunName,
  [Parameter(Mandatory)][string]$Manifest,
  [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ManifestSha256
)
$ErrorActionPreference='Stop'
$taskUtf8=[System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding=$taskUtf8
[Console]::OutputEncoding=$taskUtf8
$OutputEncoding=$taskUtf8
$env:PYTHONUTF8='1'
$env:PYTHONIOENCODING='utf-8'
$env:PUB_HOSTED_URL='https://pub.dev'
$repoPath=[IO.Path]::GetFullPath($Repo)
$dest=Join-Path $PSScriptRoot ('shared-'+$RunName+'-'+$Gate.ToLowerInvariant())
if(Test-Path -LiteralPath $dest){throw 'Never overwrite a prior gate run'}
New-Item -ItemType Directory -Path $dest | Out-Null
$freeze=Join-Path $PSScriptRoot 'android-arm64/freeze_mobile_input.py'
$nativeRoot='C:/Users/Administrator/.codex/worktrees/search-camera-history-20261003/StarChat/docs/verification/artifacts/2026-10-03/search-camera-history'
$env:PATH=(Join-Path $nativeRoot 'task-3a-windows-olm')+';'+(Join-Path $nativeRoot 'task-3b-sqlcipher-build')+';'+$env:PATH
$log=Join-Path $dest 'gate.log'
$started=[DateTimeOffset]::UtcNow.ToString('o')
$code=1
$ownedMapping=$false
$source=(& git -C $repoPath rev-parse HEAD)
if($LASTEXITCODE-ne 0){throw 'Cannot identify source'}
try {
  & py -3.12 $freeze verify --repo $repoPath --manifest $Manifest --expected-sha256 $ManifestSha256 *> (Join-Path $dest 'input-before.json')
  if($LASTEXITCODE-ne 0){throw 'Frozen input preflight failed'}
  if($Gate-eq 'Flutter') {
    $mappings=@(& subst.exe)
    if($LASTEXITCODE-ne 0 -or ($mappings-match '^W:') -or (Test-Path -LiteralPath 'W:/')){throw 'W is occupied'}
    & subst.exe W: $repoPath
    if($LASTEXITCODE-ne 0){throw 'Cannot map owned W'}
    $ownedMapping=$true
    foreach($relative in @('docs/verification/artifacts/2026-10-04/history-anchor-media-ios','docs/verification/artifacts/2026-10-03/search-camera-history')){
      [IO.Directory]::CreateDirectory((Join-Path $repoPath $relative)) | Out-Null
    }
    Push-Location -LiteralPath 'W:/apps/mobile_flutter'
    try { & C:/src/flutter/bin/flutter.bat test --no-pub --reporter expanded *> $log; $code=$LASTEXITCODE }
    finally { Pop-Location }
  } elseif($Gate-eq 'Analyze') {
    Push-Location -LiteralPath (Join-Path $repoPath 'apps/mobile_flutter')
    try { & C:/src/flutter/bin/flutter.bat analyze --no-pub *> $log; $code=$LASTEXITCODE }
    finally { Pop-Location }
  } elseif($Gate-eq 'Boundaries') {
    Push-Location -LiteralPath $repoPath
    try { & py -3.12 -m pytest -q -p no:cacheprovider tests/mobile tests/test_android_delta.py *> $log; $code=$LASTEXITCODE }
    finally { Pop-Location }
  } else {
    Push-Location -LiteralPath $repoPath
    try {
      $code=0
      foreach($file in @('tests/repository/Test-RepositoryPolicy.ps1','tests/repository/Test-DeploymentPolicy.ps1','tests/powershell/Test-TemplateTools.ps1')){
        & pwsh.exe -NoProfile -File $file *>> $log
        if($LASTEXITCODE-ne 0){$code=$LASTEXITCODE;break}
      }
    } finally {Pop-Location}
  }
  & py -3.12 $freeze verify --repo $repoPath --manifest $Manifest --expected-sha256 $ManifestSha256 *> (Join-Path $dest 'input-after.json')
  if($LASTEXITCODE-ne 0){$code=1;throw 'Frozen input changed during gate'}
} finally {
  if($ownedMapping){
    $actual=@(@(& subst.exe) | Where-Object {$_ -match '^W:\\: => '})
    if($actual.Count-eq 1 -and $actual[0]-match '^W:\\: => (.+)$' -and $Matches[1].TrimEnd('\')-eq $repoPath.TrimEnd('\')){& subst.exe W: /D}
  }
  @{gate=$Gate;source_commit=$source;manifest_sha256=$ManifestSha256;started_utc=$started;ended_utc=[DateTimeOffset]::UtcNow.ToString('o');exit_code=$code;log=$log} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dest 'receipt.json') -Encoding utf8NoBOM
}
Get-Content -LiteralPath $log -Tail 10 -Encoding utf8
exit $code
