param([ValidateSet('python-mobile','verify','ui-contract')][string]$Gate)
$ErrorActionPreference = 'Stop'
$taskUtf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $taskUtf8
[Console]::OutputEncoding = $taskUtf8
$OutputEncoding = $taskUtf8
$env:PYTHONUTF8 = '1'
$env:PYTHONIOENCODING = 'utf-8'
$env:PYTHONDONTWRITEBYTECODE = '1'
$env:NO_COLOR = '1'
$artifactDir = $PSScriptRoot
$repoDir = (Resolve-Path -LiteralPath (Join-Path $artifactDir '../../../../../..')).Path
Set-Location -LiteralPath $repoDir
$logFile = Join-Path $artifactDir "$Gate.log"
$receiptFile = Join-Path $artifactDir "$Gate-receipt.json"
if ((Test-Path -LiteralPath $logFile) -or (Test-Path -LiteralPath $receiptFile)) { throw "Do not overwrite completed evidence for $Gate" }
$commit = (& git rev-parse HEAD).Trim()
if ($commit -ne 'ec9a38a882096d80ff4a6ed1e31078dae95ee641') { throw "Unexpected candidate: $commit" }
$started = [DateTime]::UtcNow
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$exitCode = $null
$command = switch ($Gate) {
 'python-mobile' { 'py -3.12 -m pytest -q -p no:cacheprovider tests/mobile tests/test_android_delta.py' }
 'verify' { 'pwsh.exe -NoProfile -File scripts/verify.ps1' }
 'ui-contract' { 'py -3.12 scripts/verify_ui_contract.py' }
}
try {
 switch ($Gate) {
  'python-mobile' { & py -3.12 -m pytest -q -p no:cacheprovider tests/mobile tests/test_android_delta.py *> $logFile }
  'verify' { & pwsh.exe -NoProfile -File scripts/verify.ps1 *> $logFile }
  'ui-contract' { & py -3.12 scripts/verify_ui_contract.py *> $logFile }
 }
 $exitCode = $LASTEXITCODE
}
catch {
 $exitCode = 900
 $_ | Out-String | Add-Content -LiteralPath $logFile -Encoding utf8NoBOM
}
finally {
 $stopwatch.Stop()
 $ended = [DateTime]::UtcNow
 $receipt = [ordered]@{
  gate = $Gate
  command = $command
  actual_exit_code = $exitCode
  started_utc = $started.ToString('o')
  ended_utc = $ended.ToString('o')
  duration_seconds = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 6)
  candidate_commit = $commit
  candidate_after = (& git rev-parse HEAD).Trim()
  tree = (& git rev-parse 'HEAD^{tree}').Trim()
  tracked_status_after = @(& git status --short --untracked-files=no)
  cwd = $repoDir
  shell = 'pwsh.exe'
  powershell_version = $PSVersionTable.PSVersion.ToString()
  python_utf8 = $env:PYTHONUTF8
  python_io_encoding = $env:PYTHONIOENCODING
  log_file = $logFile
  log_sha256 = (Get-FileHash -LiteralPath $logFile -Algorithm SHA256).Hash.ToLowerInvariant()
  input_manifest_sha256 = (Get-FileHash -LiteralPath (Join-Path $artifactDir 'boundary-inputs-before.json') -Algorithm SHA256).Hash.ToLowerInvariant()
  mobile_manifest_sha256 = (Get-FileHash -LiteralPath (Join-Path $artifactDir '../mobile-input-manifest.json') -Algorithm SHA256).Hash.ToLowerInvariant()
 }
 $receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $receiptFile -Encoding utf8NoBOM
 $receipt | ConvertTo-Json -Depth 8
}
exit $exitCode
