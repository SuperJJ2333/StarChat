param([ValidateSet('python-mobile-final','repository-policy-final')][string]$Gate)
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
$log = Join-Path $artifactDir "$Gate.log"
$receiptFile = Join-Path $artifactDir "$Gate-receipt.json"
if ((Test-Path -LiteralPath $log) -or (Test-Path -LiteralPath $receiptFile)) { throw 'Do not overwrite final evidence' }
$commit = (& git rev-parse HEAD).Trim()
if ($commit -ne 'e432414276af7d6fe73afd9afc8b41d7bfd4b5b7') { throw "Unexpected final candidate: $commit" }
$command = switch ($Gate) {
    'python-mobile-final' { 'py -3.12 -m pytest -q -p no:cacheprovider tests/mobile tests/test_android_delta.py' }
    'repository-policy-final' { 'pwsh.exe -NoProfile -File tests/repository/Test-RepositoryPolicy.ps1' }
}
$started = [DateTime]::UtcNow
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$exitCode = $null
try {
    switch ($Gate) {
        'python-mobile-final' { & py -3.12 -m pytest -q -p no:cacheprovider tests/mobile tests/test_android_delta.py *> $log }
        'repository-policy-final' { & pwsh.exe -NoProfile -File tests/repository/Test-RepositoryPolicy.ps1 *> $log }
    }
    $exitCode = $LASTEXITCODE
}
catch {
    $exitCode = 900
    $_ | Out-String | Add-Content -LiteralPath $log -Encoding utf8NoBOM
}
finally {
    $stopwatch.Stop()
    $ended = [DateTime]::UtcNow
    [ordered]@{
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
        log_file = $log
        log_sha256 = (Get-FileHash -LiteralPath $log -Algorithm SHA256).Hash.ToLowerInvariant()
        input_manifest_sha256 = (Get-FileHash -LiteralPath (Join-Path $artifactDir 'boundary-inputs-final-before.json') -Algorithm SHA256).Hash.ToLowerInvariant()
        mobile_manifest_sha256 = (Get-FileHash -LiteralPath (Join-Path $artifactDir '../mobile-input-manifest.json') -Algorithm SHA256).Hash.ToLowerInvariant()
    } | ConvertTo-Json -Depth 8 | Tee-Object -FilePath $receiptFile
}
exit $exitCode
