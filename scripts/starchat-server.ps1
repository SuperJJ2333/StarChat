[CmdletBinding()]
param(
    [ValidateSet('Probe','Command','Upload','Download','Tunnel')][string]$Action='Probe',
    [string]$RemoteCommand,
    [string]$LocalPath,
    [string]$RemotePath,
    [ValidateRange(1024,65535)][int]$LocalPort=18944
)
$ErrorActionPreference='Stop'
$encoding=[System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding=$encoding
[Console]::OutputEncoding=$encoding
$OutputEncoding=$encoding
$env:PYTHONUTF8='1'
$env:PYTHONIOENCODING='utf-8'
$connection=@('-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','ConnectTimeout=10',
    '-o','ServerAliveInterval=15','-o','ServerAliveCountMax=2')
$target='root@207.56.8.8'
switch($Action) {
    'Probe' { & ssh @connection -J jumper -p 23421 $target true }
    'Command' {
        if([string]::IsNullOrWhiteSpace($RemoteCommand)){throw 'RemoteCommand is required.'}
        & ssh @connection -J jumper -p 23421 $target $RemoteCommand
    }
    {$_ -in 'Upload','Download'} {
        if(-not $RemotePath.StartsWith('/opt/starchat/') -or $RemotePath -notmatch '^/[A-Za-z0-9_./-]+$' -or $RemotePath.Contains('/../')){
            throw 'RemotePath must be a literal path below /opt/starchat/ without traversal or shell syntax.'
        }
        if([string]::IsNullOrWhiteSpace($LocalPath)){throw 'LocalPath is required.'}
        $remote="${target}:$RemotePath"
        if($Action -eq 'Upload') {
            if(-not (Test-Path -LiteralPath $LocalPath -PathType Leaf)){throw 'Upload requires an existing file.'}
            & scp @connection -J jumper -P 23421 -- $LocalPath $remote
        } else { & scp @connection -J jumper -P 23421 -- $remote $LocalPath }
    }
    'Tunnel' {
        # Foreground process: caller owns its lifetime and must close it after verification.
        & ssh @connection -o ExitOnForwardFailure=yes -N -D "127.0.0.1:$LocalPort" jumper
    }
}
if($LASTEXITCODE -ne 0){throw "Jump-host $Action failed (exit $LASTEXITCODE). Check jump host / target / remote command separately."}
