$ErrorActionPreference = 'Stop'

function Assert-Match([string]$Content, [string]$Pattern, [string]$Message) {
    if ($Content -notmatch $Pattern) {
        throw $Message
    }
}

$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$files = @(
    (Join-Path $root 'docker-compose.yml'),
    (Join-Path $root '.env.example'),
    (Join-Path $root 'services\matrix-bot\Dockerfile'),
    (Join-Path $root 'services\business-api\Dockerfile'),
    (Join-Path $root 'services\business-worker\Dockerfile')
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

$nginx = Get-Content -LiteralPath (Join-Path $root 'infra\nginx\nginx.conf') -Raw -Encoding UTF8
Assert-Match $nginx 'upstream\s+business_api_upstream' 'Business API upstream is required'
Assert-Match $nginx 'location\s+/api/v1/' 'Main-domain Business API route is required'
Assert-Match $nginx 'server_name\s+\{\{WWW_PUBLIC_HOSTNAME\}\}' 'www canonical host is required'
Assert-Match $nginx 'server_name\s+\{\{ADMIN_PUBLIC_HOSTNAME\}\}' 'admin host is required'
Assert-Match $nginx 'location\s+\^~\s+/_synapse/admin/' 'Public Synapse admin denial is required'

docker compose --env-file .env.example config --quiet
if ($LASTEXITCODE -ne 0) {
    throw 'docker compose config failed'
}

Write-Output 'Deployment policy: PASS'
