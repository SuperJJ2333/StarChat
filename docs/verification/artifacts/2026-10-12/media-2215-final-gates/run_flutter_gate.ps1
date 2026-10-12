param([Parameter(Mandatory)][ValidateSet('Flutter','Analyze')][string]$Gate)
$ErrorActionPreference='Stop'
$taskUtf8=[System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding=$taskUtf8
[Console]::OutputEncoding=$taskUtf8
$OutputEncoding=$taskUtf8
$env:PYTHONUTF8='1'
$env:PYTHONIOENCODING='utf-8'
$env:PUB_HOSTED_URL='https://pub.dev'
$env:FLUTTER_STORAGE_BASE_URL='https://storage.googleapis.com'
$repoPath=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../../../..'))
$nativeRoot='C:/Users/Administrator/.codex/worktrees/search-camera-history-20261003/StarChat/docs/verification/artifacts/2026-10-03/search-camera-history'
$env:PATH=(Join-Path $nativeRoot 'task-3a-windows-olm')+';'+(Join-Path $nativeRoot 'task-3b-sqlcipher-build')+';C:/src/flutter/bin;'+$env:PATH
$manifest=Join-Path $PSScriptRoot 'mobile-input-manifest.json'
$manifestHash=(Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash.ToLowerInvariant()
$freeze=Join-Path $PSScriptRoot 'freeze_mobile_input.py'
$dest=Join-Path $PSScriptRoot $Gate.ToLowerInvariant()
if(Test-Path -LiteralPath $dest){throw 'Never overwrite a gate run'}
[IO.Directory]::CreateDirectory($dest)|Out-Null
$log=Join-Path $dest 'gate.log'
$started=[DateTimeOffset]::UtcNow.ToString('o')
$source=(& git -C $repoPath rev-parse HEAD)
if($LASTEXITCODE-ne 0){throw 'Source identity failed'}
$code=1
$failure=$null
$ownedMapping=$false
$cleanup='not_needed'
$native=@{}
foreach($path in @((Join-Path $nativeRoot 'task-3a-windows-olm/libolm.dll'),(Join-Path $nativeRoot 'task-3b-sqlcipher-build/libsqlcipher.dll'))){
  $native[$path]=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
}
try {
  & py -3.12 $freeze verify --repo $repoPath --manifest $manifest --expected-sha256 $manifestHash *> (Join-Path $dest 'input-before.json')
  if($LASTEXITCODE-ne 0){throw 'Frozen input preflight failed'}
  $work=Join-Path $repoPath 'apps/mobile_flutter'
  if($Gate-eq 'Flutter'){
    $mappings=@(& subst.exe)
    if($LASTEXITCODE-ne 0 -or ($mappings-match '^V:') -or (Test-Path -LiteralPath 'V:/')){throw 'V is occupied'}
    & subst.exe V: $repoPath
    if($LASTEXITCODE-ne 0){throw 'Cannot map owned V'}
    $ownedMapping=$true
    $work='V:/apps/mobile_flutter'
    # Existing tests create diagnostic fixtures only below these ignored paths.
    foreach($relative in @('docs/verification/artifacts/2026-10-04/history-anchor-media-ios','docs/verification/artifacts/2026-10-03/search-camera-history')){
      [IO.Directory]::CreateDirectory((Join-Path $repoPath $relative))|Out-Null
    }
  }
  Push-Location -LiteralPath $work
  try {
    if($Gate-eq 'Flutter'){
      & C:/src/flutter/bin/flutter.bat test --no-pub --reporter expanded *> $log
    }else{
      & C:/src/flutter/bin/flutter.bat analyze --no-pub *> $log
    }
    $code=$LASTEXITCODE
  }finally{Pop-Location}
  & py -3.12 $freeze verify --repo $repoPath --manifest $manifest --expected-sha256 $manifestHash *> (Join-Path $dest 'input-after.json')
  if($LASTEXITCODE-ne 0){$code=1;throw 'Frozen inputs changed during gate'}
}catch{
  $failure=$_.Exception.Message
  if($code-eq 0){$code=1}
}finally{
  if($ownedMapping){
    $actual=@(@(& subst.exe)|Where-Object{$_-match '^V:'})
    if($actual.Count-eq 1 -and $actual[0]-match '^V:\\: => (.+)$' -and $Matches[1].TrimEnd('\')-eq $repoPath.TrimEnd('\')){
      & subst.exe V: /D
      $cleanup=if($LASTEXITCODE-eq 0){'removed_owned_V'}else{'remove_failed'}
    }else{$cleanup='mapping_changed_not_removed'}
  }
  @{gate=$Gate;source_commit=$source;manifest_sha256=$manifestHash;started_utc=$started;ended_utc=[DateTimeOffset]::UtcNow.ToString('o');exit_code=$code;failure=$failure;mapping_cleanup=$cleanup;native_dll_sha256=$native;log=$log}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $dest 'receipt.json') -Encoding utf8
}
if(Test-Path -LiteralPath $log){Get-Content -LiteralPath $log -Encoding utf8 -Tail 8}
if($failure){Write-Output $failure}
exit $code
