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
Assert-Match $nginx 'resolver\s+127\.0\.0\.11' 'Docker DNS resolver is required for recreated upstream containers'
if ([regex]::Matches($nginx, 'server\s+[a-z-]+:\d+\s+resolve;').Count -lt 3) {
    throw 'All gateway upstreams must dynamically resolve recreated containers'
}
Assert-Match $nginx 'upstream\s+business_api_upstream' 'Business API upstream is required'
Assert-Match $nginx 'location\s+/api/v1/' 'Main-domain Business API route is required'
Assert-Match $nginx 'server_name\s+\{\{WWW_PUBLIC_HOSTNAME\}\}' 'www canonical host is required'
Assert-Match $nginx 'server_name\s+\{\{ADMIN_PUBLIC_HOSTNAME\}\}' 'admin host is required'
Assert-Match $nginx 'location\s+\^~\s+/_synapse/admin/' 'Public Synapse admin denial is required'
if ($nginx -match 'listen\s+443\s+ssl\s+http2') {
    throw 'Deprecated listen http2 syntax is forbidden'
}
Assert-Match $nginx 'http2\s+on;' 'Modern HTTP/2 directive is required'

$environmentExample = Get-Content -LiteralPath (Join-Path $root '.env.example') -Raw -Encoding UTF8
Assert-Match $environmentExample '(?m)^NGINX_IMAGE=nginx:1\.27\.5-alpine$' 'Pinned production Nginx image is required'
Assert-Match $environmentExample '(?m)^WWW_PUBLIC_HOSTNAME=www\.example\.com$' 'www production hostname example is required'
Assert-Match $environmentExample '(?m)^ADMIN_PUBLIC_HOSTNAME=admin\.example\.com$' 'admin production hostname example is required'
Assert-Match $environmentExample '(?m)^BUSINESS_MATRIX_PUBLIC_HOMESERVER_URL=https://example\.com/$' 'Matrix public HTTPS example is required'
Assert-Match $environmentExample '(?m)^BUSINESS_AVATAR_PUBLIC_BASE_URL=https://example\.com$' 'Avatar public HTTPS example is required'
Assert-Match $environmentExample '(?m)^EMAIL_VERIFICATION_PUBLIC_BASE_URL=https://example\.com$' 'Email public HTTPS example is required'

$mobileRelease = Get-Content -LiteralPath (Join-Path $root 'docs\runbooks\mobile-release.md') -Raw -Encoding UTF8
Assert-Match $mobileRelease 'LIUHETONG_BUSINESS_API_URL=https://liuhetong888\.com' 'Mobile release Business API domain is required'
Assert-Match $mobileRelease 'LIUHETONG_MATRIX_HOMESERVER=https://liuhetong888\.com' 'Mobile release Matrix domain is required'

docker compose --env-file .env.example config --quiet
if ($LASTEXITCODE -ne 0) {
    throw 'docker compose config failed'
}

$productionComposePath = Join-Path $root 'docker-compose.production.yml'
if (-not (Test-Path -LiteralPath $productionComposePath)) {
    throw 'Production Compose override is required'
}
$productionCompose = Get-Content -LiteralPath $productionComposePath -Raw -Encoding UTF8
Assert-Match $productionCompose '(?m)^\s*gateway:' 'Production gateway service is required'
Assert-Match $productionCompose '/etc/nginx/conf\.d/default\.conf:ro' 'Gateway config must be mounted inside the Nginx http context'
Assert-Match $productionCompose '127\.0\.0\.1:\$\{SYNAPSE_HTTP_PORT' 'Synapse must bind only to loopback in production'
Assert-Match $productionCompose '127\.0\.0\.1:\$\{BUSINESS_API_HTTP_PORT' 'Business API must bind only to loopback in production'
Assert-Match $productionCompose '127\.0\.0\.1:\$\{ELEMENT_HTTP_PORT' 'Element must bind only to loopback in production'
Assert-Match $productionCompose '80:80' 'Gateway must publish HTTP for certificate renewal and redirect'
Assert-Match $productionCompose '443:443' 'Gateway must publish HTTPS'

$baseCompose = Get-Content -LiteralPath (Join-Path $root 'docker-compose.yml') -Raw -Encoding UTF8
if ([regex]::Matches($baseCompose, 'BUSINESS_MATRIX_PUBLIC_HOMESERVER_URL:\s+\$\{BUSINESS_MATRIX_PUBLIC_HOMESERVER_URL').Count -lt 2) {
    throw 'Business API and Worker must both receive the production Matrix public URL'
}
if ([regex]::Matches($baseCompose, 'BUSINESS_AVATAR_PUBLIC_BASE_URL:\s+\$\{BUSINESS_AVATAR_PUBLIC_BASE_URL').Count -lt 2) {
    throw 'Business API and Worker must both receive the production avatar public URL'
}

docker compose --env-file .env.example -f docker-compose.yml -f docker-compose.production.yml config --quiet
if ($LASTEXITCODE -ne 0) {
    throw 'production docker compose config failed'
}

Write-Output 'Deployment policy: PASS'
