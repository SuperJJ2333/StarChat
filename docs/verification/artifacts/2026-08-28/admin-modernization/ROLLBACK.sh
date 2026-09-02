param([Parameter(Mandatory)][string]$Target,[Parameter(Mandatory)][string]$Backup)
if(Test-Path -LiteralPath $Target){ Remove-Item -LiteralPath $Target -Recurse -Force }
Copy-Item -LiteralPath $Backup -Destination $Target -Recurse -Force
Write-Output "ROLLBACK_RESTORED"
