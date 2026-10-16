$ErrorActionPreference='Stop'
$taskUtf8=[Text.UTF8Encoding]::new($false)
[Console]::InputEncoding=$taskUtf8; [Console]::OutputEncoding=$taskUtf8; $OutputEncoding=$taskUtf8
$env:PYTHONUTF8='1'; $env:PYTHONIOENCODING='utf-8'
$taskReceipt=Join-Path $PSScriptRoot 'tunnel-start.json'
if(Test-Path -LiteralPath $taskReceipt){throw 'Refuse to overwrite tunnel ownership receipt'}
$taskListener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
$taskListener.Start(); $taskPort=$taskListener.LocalEndpoint.Port; $taskListener.Stop()
$taskSsh=(Get-Command ssh.exe -ErrorAction Stop).Source
$taskProcess=Start-Process -FilePath $taskSsh -ArgumentList @('-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','ConnectTimeout=10','-o','ExitOnForwardFailure=yes','-o','ServerAliveInterval=15','-o','ServerAliveCountMax=2','-N','-D',"127.0.0.1:$taskPort",'jumper') -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $PSScriptRoot 'tunnel-stdout.log') -RedirectStandardError (Join-Path $PSScriptRoot 'tunnel-stderr.log')
$taskStarted=$taskProcess.StartTime.ToUniversalTime().ToString('o')
$taskReady=$false
try {
    for($taskTry=0;$taskTry -lt 40;$taskTry++){
        $taskProcess.Refresh(); if($taskProcess.HasExited){throw 'Own SSH tunnel exited during startup'}
        $taskClient=[Net.Sockets.TcpClient]::new()
        try {$taskClient.Connect('127.0.0.1',$taskPort);$taskReady=$true;break} catch {Start-Sleep -Milliseconds 250} finally {$taskClient.Dispose()}
    }
    if(-not $taskReady){throw 'Own SSH listener did not become ready'}
    [ordered]@{status='LOCAL_LISTENER_READY_ONLY';pid=$taskProcess.Id;start_utc=$taskStarted;executable=$taskSsh;host='127.0.0.1';port=$taskPort;public_release_requests=0;requires_root_publish_go=$true} | ConvertTo-Json | Set-Content -LiteralPath $taskReceipt -Encoding utf8NoBOM
    Get-Content -LiteralPath $taskReceipt -Encoding utf8
} catch {
    $taskProcess.Refresh(); if(-not $taskProcess.HasExited){$taskProcess.Kill();$taskProcess.WaitForExit(5000)|Out-Null}
    throw
}
