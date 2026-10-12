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
$log = Join-Path $artifactDir 'delta-fixture-recheck.log'
$receiptFile = Join-Path $artifactDir 'delta-fixture-recheck-receipt.json'
if ((Test-Path -LiteralPath $log) -or (Test-Path -LiteralPath $receiptFile)) { throw 'Do not overwrite delta recheck evidence' }
$started = [DateTime]::UtcNow
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
& py -3.12 -m pytest -q -p no:cacheprovider tests/test_android_delta.py *> $log
$exitCode = $LASTEXITCODE
$stopwatch.Stop()
[ordered]@{
    command = 'py -3.12 -m pytest -q -p no:cacheprovider tests/test_android_delta.py'
    actual_exit_code = $exitCode
    candidate_commit = (& git rev-parse HEAD).Trim()
    started_utc = $started.ToString('o')
    ended_utc = [DateTime]::UtcNow.ToString('o')
    duration_seconds = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 6)
    log_file = $log
    log_sha256 = (Get-FileHash -LiteralPath $log -Algorithm SHA256).Hash.ToLowerInvariant()
    input_manifest_sha256 = (Get-FileHash -LiteralPath (Join-Path $artifactDir 'delta-inputs-before.json') -Algorithm SHA256).Hash.ToLowerInvariant()
    tracked_status_after = @(& git status --short --untracked-files=no)
    environment_preparation = 'Created only the ignored parent already required by the unchanged test. No monkeypatch, assertion change, alternate implementation, or test exclusion.'
} | ConvertTo-Json -Depth 8 | Tee-Object -FilePath $receiptFile
exit $exitCode
