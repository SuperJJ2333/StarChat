$ErrorActionPreference='Stop'
$taskUtf8=[Text.UTF8Encoding]::new($false)
[Console]::InputEncoding=$taskUtf8; [Console]::OutputEncoding=$taskUtf8; $OutputEncoding=$taskUtf8
$env:PYTHONUTF8='1'; $env:PYTHONIOENCODING='utf-8'
$taskReceipt=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'tunnel-start.json') -Raw -Encoding utf8 | ConvertFrom-Json
$taskProcess=Get-Process -Id $taskReceipt.pid -ErrorAction SilentlyContinue
$taskStopped=$false
if($taskProcess){
    if($taskProcess.StartTime.ToUniversalTime().Ticks -ne ([datetime]$taskReceipt.start_utc).ToUniversalTime().Ticks -or $taskProcess.Path -ne $taskReceipt.executable){throw 'PID owner identity mismatch; refuse to stop'}
    Stop-Process -InputObject $taskProcess -ErrorAction Stop
    $taskProcess.WaitForExit(5000)|Out-Null
    $taskStopped=$taskProcess.HasExited
} else {$taskStopped=$true}
[ordered]@{checked_at_utc=[DateTime]::UtcNow.ToString('o');owned_pid=$taskReceipt.pid;own_process_stopped_or_already_exited=$taskStopped;other_processes_touched=$false} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'tunnel-stop.json') -Encoding utf8NoBOM
if(-not $taskStopped){throw 'Own SSH process did not exit'}
