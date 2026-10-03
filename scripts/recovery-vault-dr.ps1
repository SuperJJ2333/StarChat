param(
    [Parameter(Mandatory)][ValidateSet('backup','restore-send')][string]$Action,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$KeyId,
    [Parameter(Mandatory)][string]$Python
)
$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$env:PYTHONUTF8 = '1'
$env:PYTHONIOENCODING = 'utf-8'
$helper = Join-Path $PSScriptRoot '../third_party/synapse/chatflow_recovery_provider.py'
& $Python $helper $Action $KeyId
if ($LASTEXITCODE -ne 0) { throw 'Recovery credential operation unavailable' }
