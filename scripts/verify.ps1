$ErrorActionPreference = 'Stop'

$utf8 = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = $utf8
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$env:PYTHONUTF8 = '1'
$env:PYTHONIOENCODING = 'utf-8'

$projectRoot = Split-Path -Parent $PSScriptRoot
$previousLocation = Get-Location

function Assert-LastExitCode {
    param([string]$Step)

    if ($LASTEXITCODE -ne 0) {
        throw "$Step failed with exit code $LASTEXITCODE"
    }
}

try {
    Set-Location -LiteralPath $projectRoot

    Write-Output '== Repository policy =='
    & pwsh -NoProfile -File tests/repository/Test-RepositoryPolicy.ps1
    Assert-LastExitCode 'Repository policy'

    Write-Output '== Deployment policy =='
    & pwsh -NoProfile -File tests/repository/Test-DeploymentPolicy.ps1
    Assert-LastExitCode 'Deployment policy'

    Write-Output '== Template unit tests =='
    & pwsh -NoProfile -File tests/powershell/Test-TemplateTools.ps1
    Assert-LastExitCode 'Template unit tests'

    Write-Output '== Render-only configuration smoke test =='
    & pwsh -NoProfile -File scripts/init_matrix.ps1 -RenderOnly
    Assert-LastExitCode 'Render-only configuration smoke test'

    $element = Get-Content -LiteralPath 'data/element/config.json' -Raw -Encoding UTF8 | ConvertFrom-Json
    $baseUrl = [string]$element.default_server_config.'m.homeserver'.base_url
    $serverName = [string]$element.default_server_config.'m.homeserver'.server_name
    if ($baseUrl.StartsWith('{') -or $baseUrl.EndsWith('}')) {
        throw "Element base_url contains wrapper braces: $baseUrl"
    }
    if ($serverName.StartsWith('{') -or $serverName.EndsWith('}')) {
        throw "Element server_name contains wrapper braces: $serverName"
    }

    $unresolved = Select-String `
        -LiteralPath 'data/synapse/homeserver.yaml', 'data/element/config.json' `
        -Pattern '\{\{[A-Z][A-Z0-9_]*\}\}' `
        -Encoding UTF8
    if ($unresolved) {
        throw 'Rendered configuration contains unresolved template tokens.'
    }

    Write-Output '== Infra render tests =='
    & py -3.12 -m pytest tests/infra -q
    Assert-LastExitCode 'Infra render tests'

    Write-Output '== Getui bridge tests =='
    $env:PYTHONPATH = 'services/getui-bridge'
    & py -3.12 -m pytest tests/getui_bridge -q
    Assert-LastExitCode 'Getui bridge tests'

    Write-Output '== Matrix Bot tests =='
    $env:PYTHONPATH = 'services/matrix-bot'
    & python -m pytest tests/matrix_bot -q
    Assert-LastExitCode 'Matrix Bot tests'

    Write-Output '== Business API and Worker tests =='
    $env:PYTHONPATH = "services/business-api;services/business-worker/app;$projectRoot"
    & py -3.12 -m pytest tests/business_api tests/business_worker -q
    Assert-LastExitCode 'Business API and Worker tests'

    Write-Output '== Flutter boundary tests =='
    & py -3.12 -m pytest tests/mobile -q
    Assert-LastExitCode 'Flutter boundary tests'

    Write-Output '== Flutter-HTML-Figma UI contract drift check =='
    & py -3.12 scripts/verify_ui_contract.py
    Assert-LastExitCode 'Flutter-HTML-Figma UI contract drift check'

    Write-Output '== Business API import smoke test =='
    & py -3.12 -c "import app.main; print('Business API import: PASS')"
    Assert-LastExitCode 'Business API import smoke test'

    Write-Output '== Python AST parse =='
    @'
import ast
from pathlib import Path

files = sorted(Path("services/matrix-bot/app").glob("*.py"))
files += sorted(Path("services/business-api/app").rglob("*.py"))
files += sorted(Path("services/business-worker/app").rglob("*.py"))
for path in files:
    ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
print(f"AST parse: PASS ({len(files)} files)")
'@ | & py -3.12 -
    Assert-LastExitCode 'Python AST parse'

    Write-Output '== Business database migrations =='
    Push-Location -LiteralPath 'services/business-api'
    try {
        $env:PYTHONPATH = '.'
        $heads = @(& py -3.12 -m alembic heads)
        Assert-LastExitCode 'Alembic heads'
        $headCount = @($heads | Where-Object { $_ -match '\(head\)' }).Count
        if ($headCount -ne 1) {
            throw "Expected exactly one Alembic head, found $headCount"
        }
        & py -3.12 -m alembic upgrade head --sql | Out-Null
        Assert-LastExitCode 'Alembic offline upgrade'
        Write-Output 'Alembic migrations: PASS'
    }
    finally {
        Pop-Location
    }

    Write-Output '== OpenAPI drift check =='
    $env:PYTHONPATH = "services/business-api;$projectRoot"
    & py -3.12 scripts/export_openapi.py --check
    Assert-LastExitCode 'OpenAPI drift check'

    Write-Output '== Docker Compose render =='
    & docker compose --env-file .env.example config --quiet
    Assert-LastExitCode 'Docker Compose render'

    Write-Output 'Verification: PASS'
}
finally {
    Set-Location -LiteralPath $previousLocation
}
