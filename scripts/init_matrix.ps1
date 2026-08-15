param(
    [switch]$StartAll,
    [switch]$RenderOnly
)

$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$envFile = Join-Path $projectRoot ".env"
Import-Module (Join-Path $PSScriptRoot "lib/TemplateTools.psm1") -Force

if (-not (Test-Path $envFile)) {
    throw "Missing .env. Copy .env.example to .env and fill in your secrets first."
}

function Get-EnvOrDefault {
    param(
        [string]$Name,
        [string]$DefaultValue
    )

    $value = [System.Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $DefaultValue
    }

    return $value
}

function Import-DotEnv {
    param([string]$Path)

    Get-Content $Path | ForEach-Object {
        $line = $_.Trim()
        if (-not $line -or $line.StartsWith("#")) {
            return
        }

        $parts = $line.Split("=", 2)
        if ($parts.Count -ne 2) {
            return
        }

        [System.Environment]::SetEnvironmentVariable($parts[0], $parts[1])
    }
}

function Wait-ForSynapse {
    param([string]$Url)

    $deadline = (Get-Date).AddMinutes(3)
    while ((Get-Date) -lt $deadline) {
        try {
            $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5
            if ($response.StatusCode -eq 200) {
                return
            }
        } catch {
            Start-Sleep -Seconds 3
        }
    }

    throw "Synapse did not become ready in time."
}

function Invoke-RegistrationScript {
    param([string]$ScriptPath)

    $output = docker compose exec -T `
        -e SYNAPSE_ADMIN_USERNAME=$env:SYNAPSE_ADMIN_USERNAME `
        -e SYNAPSE_ADMIN_PASSWORD=$env:SYNAPSE_ADMIN_PASSWORD `
        -e SYNAPSE_BOT_USERNAME=$env:SYNAPSE_BOT_USERNAME `
        -e SYNAPSE_BOT_PASSWORD=$env:SYNAPSE_BOT_PASSWORD `
        synapse sh $ScriptPath 2>&1

    if ($LASTEXITCODE -eq 0) {
        Write-Host $output
        return
    }

    if ($output -match "already taken") {
        Write-Host $output
        Write-Host "User already exists, continuing."
        return
    }

    throw $output
}

Import-DotEnv -Path $envFile

$requiredVars = @(
    "POSTGRES_DB",
    "POSTGRES_USER",
    "POSTGRES_PASSWORD",
    "POSTGRES_HOST",
    "POSTGRES_PORT",
    "MATRIX_SERVER_NAME",
    "SYNAPSE_PUBLIC_BASEURL",
    "SYNAPSE_INTERNAL_BASEURL",
    "SYNAPSE_REGISTRATION_SHARED_SECRET",
    "SYNAPSE_MACAROON_SECRET_KEY",
    "SYNAPSE_FORM_SECRET",
    "SYNAPSE_ADMIN_USERNAME",
    "SYNAPSE_ADMIN_PASSWORD",
    "SYNAPSE_BOT_USERNAME",
    "SYNAPSE_BOT_PASSWORD"
)

foreach ($name in $requiredVars) {
    if (-not [System.Environment]::GetEnvironmentVariable($name)) {
        throw "Environment variable $name is required in .env."
    }
}

$dataRoot = Join-Path $projectRoot "data"
$synapseData = Join-Path $dataRoot "synapse"
$elementData = Join-Path $dataRoot "element"
$botData = Join-Path $dataRoot "bot"
$postgresData = Join-Path $dataRoot "postgres"

foreach ($path in @($dataRoot, $synapseData, $elementData, $botData, $postgresData)) {
    if (-not (Test-Path $path)) {
        New-Item -ItemType Directory -Path $path | Out-Null
    }
}

$homeserverConfig = Join-Path $synapseData "homeserver.yaml"
$signingKey = Join-Path $synapseData "$($env:MATRIX_SERVER_NAME).signing.key"

if (-not $RenderOnly -and (-not (Test-Path $homeserverConfig) -or -not (Test-Path $signingKey))) {
    Write-Host "Generating initial Synapse config and signing keys..."
    $synapseImage = Get-EnvOrDefault -Name "SYNAPSE_IMAGE" -DefaultValue "matrixdotorg/synapse:latest"
    docker run --rm `
        -e SYNAPSE_SERVER_NAME=$env:MATRIX_SERVER_NAME `
        -e SYNAPSE_REPORT_STATS=no `
        -v "${synapseData}:/data" `
        $synapseImage generate

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to generate initial Synapse config."
    }
}

$variables = @{
    POSTGRES_DB = $env:POSTGRES_DB
    POSTGRES_USER = $env:POSTGRES_USER
    POSTGRES_PASSWORD = $env:POSTGRES_PASSWORD
    POSTGRES_HOST = $env:POSTGRES_HOST
    POSTGRES_PORT = $env:POSTGRES_PORT
    MATRIX_SERVER_NAME = $env:MATRIX_SERVER_NAME
    SYNAPSE_PUBLIC_BASEURL = $env:SYNAPSE_PUBLIC_BASEURL
    SYNAPSE_REGISTRATION_SHARED_SECRET = $env:SYNAPSE_REGISTRATION_SHARED_SECRET
    SYNAPSE_MACAROON_SECRET_KEY = $env:SYNAPSE_MACAROON_SECRET_KEY
    SYNAPSE_FORM_SECRET = $env:SYNAPSE_FORM_SECRET
    TURN_URI_UDP = Get-EnvOrDefault -Name "TURN_URI_UDP" -DefaultValue "turn:10.0.2.2:3478?transport=udp"
    TURN_URI_TCP = Get-EnvOrDefault -Name "TURN_URI_TCP" -DefaultValue "turn:10.0.2.2:3478?transport=tcp"
    TURN_SHARED_SECRET = Get-EnvOrDefault -Name "TURN_SHARED_SECRET" -DefaultValue "development-turn-shared-secret"
}

if ($env:BUSINESS_ENVIRONMENT -eq 'production') {
    $turnSecret = [System.Environment]::GetEnvironmentVariable('TURN_SHARED_SECRET')
    if ([string]::IsNullOrWhiteSpace($turnSecret) -or
        $turnSecret.StartsWith('change-this', [System.StringComparison]::OrdinalIgnoreCase) -or
        $turnSecret.StartsWith('development-', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Production requires a non-placeholder TURN_SHARED_SECRET.'
    }
}

Write-RenderedTemplate `
    -TemplatePath (Join-Path $projectRoot "infra/synapse/homeserver.yaml.template") `
    -DestinationPath $homeserverConfig `
    -Variables $variables

Copy-Item `
    (Join-Path $projectRoot "infra/synapse/log.config") `
    (Join-Path $synapseData "log.config") `
    -Force

Write-RenderedTemplate `
    -TemplatePath (Join-Path $projectRoot "infra/element/config.json.template") `
    -DestinationPath (Join-Path $elementData "config.json") `
    -Variables @{
        MATRIX_SERVER_NAME = $env:MATRIX_SERVER_NAME
        SYNAPSE_PUBLIC_BASEURL = $env:SYNAPSE_PUBLIC_BASEURL
    }

if ($RenderOnly) {
    Write-Host "Configuration rendering complete."
    return
}

Write-Host "Starting postgres and synapse..."
docker compose up -d postgres synapse
if ($LASTEXITCODE -ne 0) {
    throw "Failed to start postgres and synapse."
}

$synapseReadyUrl = "{0}_matrix/client/versions" -f $env:SYNAPSE_PUBLIC_BASEURL
Wait-ForSynapse -Url $synapseReadyUrl

Write-Host "Registering admin account..."
Invoke-RegistrationScript -ScriptPath "/scripts/register_admin.sh"

Write-Host "Registering bot account..."
Invoke-RegistrationScript -ScriptPath "/scripts/register_bot.sh"

if ($StartAll) {
    Write-Host "Starting element-web and matrix-bot..."
    docker compose up -d element-web matrix-bot
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to start element-web and matrix-bot."
    }
}

Write-Host ""
Write-Host "Initialization complete."
Write-Host "Synapse URL: $($env:SYNAPSE_PUBLIC_BASEURL)"
Write-Host "Element URL: $($env:ELEMENT_PUBLIC_URL)"
$botPort = Get-EnvOrDefault -Name "MATRIX_BOT_HTTP_PORT" -DefaultValue "8081"
Write-Host "Bot webhook: http://127.0.0.1:${botPort}/internal/matrix/publish"
