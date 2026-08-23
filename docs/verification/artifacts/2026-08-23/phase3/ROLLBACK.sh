#!/usr/bin/env pwsh
param([string]$Source='apps/mobile_flutter/lib/features/matrix/group_chat_info_controller.dart')
$copy='MODIFIED_FILE'
if (Test-Path -LiteralPath $copy) { Copy-Item -LiteralPath $copy -Destination $copy.rollback -Force; Write-Output 'restored behavior/status: rollback copy created' }
