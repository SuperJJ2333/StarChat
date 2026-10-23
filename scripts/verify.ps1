param([string]$Python = '', [switch]$PreflightOnly)

$ErrorActionPreference = 'Stop'

$utf8 = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = $utf8
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$env:PYTHONUTF8 = '1'
$env:PYTHONIOENCODING = 'utf-8'

$projectRoot = Split-Path -Parent $PSScriptRoot
$previousLocation = Get-Location
$savedEnvironment = @{}
foreach ($name in @('PYTHONPATH', 'PYTHONHOME', 'PYTHONNOUSERSITE', 'PYTEST_ADDOPTS', 'PATH')) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
}
if (-not $Python) {
    $Python = Join-Path $projectRoot $(if ($IsWindows) { '.venv312/Scripts/python.exe' } else { '.venv312/bin/python' })
}
$pythonExecutable = (Resolve-Path -LiteralPath $Python -ErrorAction Stop).Path

function Assert-LastExitCode {
    param([string]$Step)

    if ($LASTEXITCODE -ne 0) {
        throw "$Step failed with exit code $LASTEXITCODE"
    }
}

try {
    Set-Location -LiteralPath $projectRoot

    $env:PYTHONHOME = $null
    $env:PYTHONNOUSERSITE = '1'
    $env:PATH = (Split-Path -Parent $pythonExecutable) + [IO.Path]::PathSeparator + $env:PATH
    $env:PYTHONPATH = @("$projectRoot/services/business-api", "$projectRoot/services/business-worker/app", $projectRoot) -join [IO.Path]::PathSeparator
    & $pythonExecutable scripts/python_environment.py check
    Assert-LastExitCode 'Python environment'
    & $pythonExecutable -m pip check
    Assert-LastExitCode 'Python dependencies'
    $stdinResult = @('print("Python stdin: PASS (输入)")' | & $pythonExecutable -)
    Assert-LastExitCode 'Python stdin'
    if ($stdinResult.Count -ne 1 -or $stdinResult[0] -cne 'Python stdin: PASS (输入)') {
        throw 'Python stdin did not execute the expected UTF-8 input'
    }
    Write-Output $stdinResult[0]
    @'
from pathlib import Path
import sys
try:
    from app.core.config import Settings
    settings = Settings()
    if settings.environment == 'production':
        raise ValueError('Use a local test configuration')
    import app.main
    import tests
    if not Path(app.main.__file__).resolve().is_relative_to(Path.cwd() / 'services/business-api'):
        raise ValueError('Business API module is outside this worktree')
    if not any(Path(p).resolve() == Path.cwd() / 'tests' for p in tests.__path__):
        raise ValueError('Tests module is outside this worktree')
except Exception as error:
    # Do not print ValidationError inputs: they can contain configuration secrets.
    print('Business configuration/import preflight failed: ' + type(error).__name__ +
          '. Check local .env, module paths and BUSINESS_SMS_ALIYUN_CODE_VALID_MINUTES=15.', file=sys.stderr)
    raise SystemExit(1)
print('Business configuration/import: PASS')
'@ | & $pythonExecutable -
    Assert-LastExitCode 'Business configuration/import preflight'
    Write-Output 'Preflight: PASS'
    if ($PreflightOnly) { return }
    if (-not (Test-Path -LiteralPath '.env')) { throw 'Missing local .env; copy .env.example in an isolated worktree first' }
    $runId = 'verify-' + [DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N')
    $runDirectory = Join-Path $projectRoot "docs/verification/artifacts/$([DateTimeOffset]::Now.ToString('yyyy-MM-dd'))/$runId"
    New-Item -ItemType Directory -Path $runDirectory | Out-Null
    # pytest uses shell splitting for PYTEST_ADDOPTS, including on Windows.
    # The unique directory is task-owned; never reuse caller-supplied basetemp.
    $safeTemp = (Join-Path $runDirectory 'pytest').Replace('\', '/')
    $env:PYTEST_ADDOPTS = '-ra --basetemp="' + $safeTemp + '"'
    Write-Output "Verification artifacts: $runDirectory"

    Write-Output '== Developer environment integration tests =='
    & $pythonExecutable -m pytest tests/development -q
    Assert-LastExitCode 'Developer environment integration tests'

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
    & $pythonExecutable -m pytest tests/infra -q
    Assert-LastExitCode 'Infra render tests'

    Write-Output '== Getui bridge tests =='
    $env:PYTHONPATH = 'services/getui-bridge'
    & $pythonExecutable -m pytest tests/getui_bridge -q
    Assert-LastExitCode 'Getui bridge tests'

    Write-Output '== Matrix Bot tests =='
    $env:PYTHONPATH = 'services/matrix-bot'
    & $pythonExecutable -m pytest tests/matrix_bot -q
    Assert-LastExitCode 'Matrix Bot tests'

    Write-Output '== Business API and Worker tests =='
    $env:PYTHONPATH = @('services/business-api', 'services/business-worker/app', $projectRoot) -join [IO.Path]::PathSeparator
    & $pythonExecutable -m pytest tests/business_api tests/business_worker -q
    Assert-LastExitCode 'Business API and Worker tests'

    Write-Output '== Flutter boundary tests =='
    & $pythonExecutable -m pytest tests/mobile -q
    Assert-LastExitCode 'Flutter boundary tests'

    Write-Output '== Flutter-HTML UI contract drift check =='
    & $pythonExecutable scripts/verify_ui_contract.py
    Assert-LastExitCode 'Flutter-HTML UI contract drift check'

    Write-Output '== Business API import smoke test =='
    & $pythonExecutable -c "import app.main; print('Business API import: PASS')"
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
'@ | & $pythonExecutable -
    Assert-LastExitCode 'Python AST parse'

    Write-Output '== Business database migrations =='
    Push-Location -LiteralPath 'services/business-api'
    try {
        $env:PYTHONPATH = '.'
        $heads = @(& $pythonExecutable -m alembic heads)
        Assert-LastExitCode 'Alembic heads'
        $headCount = @($heads | Where-Object { $_ -match '\(head\)' }).Count
        if ($headCount -ne 1) {
            throw "Expected exactly one Alembic head, found $headCount"
        }
        & $pythonExecutable -m alembic upgrade head --sql | Out-Null
        Assert-LastExitCode 'Alembic offline upgrade'
        Write-Output 'Alembic migrations: PASS'
    }
    finally {
        Pop-Location
    }

    Write-Output '== OpenAPI drift check =='
    $env:PYTHONPATH = @('services/business-api', $projectRoot) -join [IO.Path]::PathSeparator
    & $pythonExecutable scripts/export_openapi.py --check
    Assert-LastExitCode 'OpenAPI drift check'

    Write-Output '== Docker Compose render =='
    & docker compose --env-file .env.example config --quiet
    Assert-LastExitCode 'Docker Compose render'

    Write-Output 'Verification: PASS'
}
finally {
    foreach ($name in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name])
    }
    Set-Location -LiteralPath $previousLocation
}
