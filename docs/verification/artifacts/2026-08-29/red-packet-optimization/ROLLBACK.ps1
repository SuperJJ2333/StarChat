# Red packet optimization rollback
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))))
$baseline = Join-Path $PSScriptRoot 'baseline'
Get-ChildItem -LiteralPath $baseline -Recurse -File | ForEach-Object {
  $relative = $_.FullName.Substring($baseline.Length).TrimStart('\','/')
  $destination = Join-Path $root $relative
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
  Copy-Item -LiteralPath $_.FullName -Destination $destination -Force
}
Write-Output 'RESTORED_BASELINE=OK'

