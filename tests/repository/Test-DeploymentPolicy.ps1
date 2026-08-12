$ErrorActionPreference = 'Stop'

$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$files = @(
    (Join-Path $root 'docker-compose.yml'),
    (Join-Path $root '.env.example'),
    (Join-Path $root 'services\matrix-bot\Dockerfile')
)
$localEnvironment = Join-Path $root '.env'
if (Test-Path -LiteralPath $localEnvironment) {
    $files += $localEnvironment
}

foreach ($file in $files) {
    $content = Get-Content -LiteralPath $file -Raw -Encoding UTF8
    if ($content -match '(?i)(?:^|[:=])latest(?:\s|$|\})') {
        throw "floating latest reference found in $file"
    }
}

docker compose --env-file .env.example config --quiet
if ($LASTEXITCODE -ne 0) {
    throw 'docker compose config failed'
}

Write-Output 'Deployment policy: PASS'
