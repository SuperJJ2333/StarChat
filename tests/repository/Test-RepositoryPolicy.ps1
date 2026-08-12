$ErrorActionPreference = 'Stop'

$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

$gitignore = Get-Content (Join-Path $root '.gitignore') -Raw -Encoding UTF8
Assert-True ($gitignore -match '(?m)^\.superpowers/$') '.superpowers/ must be ignored'
Assert-True (Test-Path (Join-Path $root 'AGENTS.md')) 'root AGENTS.md is required'
Assert-True (Test-Path (Join-Path $root 'infra\AGENTS.md')) 'infra AGENTS.md is required'
Assert-True (Test-Path (Join-Path $root 'services\matrix-bot\AGENTS.md')) 'matrix-bot AGENTS.md is required'
Assert-True (Test-Path (Join-Path $root 'scripts\verify.ps1')) 'scripts/verify.ps1 is required'
Assert-True (Test-Path (Join-Path $root 'services\matrix-bot\requirements-dev.txt')) 'matrix-bot development requirements are required'

$readme = Get-Content (Join-Path $root 'README.md') -Raw -Encoding UTF8
Assert-True ($readme.Contains('pwsh -NoProfile -File scripts/verify.ps1')) 'README must document the verification command'
Assert-True ($readme.Contains('2026-08-12-starchat-product-modernization-design.md')) 'README must link the approved design'

Write-Output 'Repository policy: PASS'
