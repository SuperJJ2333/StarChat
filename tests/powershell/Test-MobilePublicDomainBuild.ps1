$ErrorActionPreference = 'Stop'

$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$scriptPath = Join-Path $root 'scripts\build_mobile_public_domain.ps1'

if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw 'public-domain mobile build script is required'
}

function Invoke-Validation([string]$BaseUrl) {
    & pwsh.exe -NoProfile -File $scriptPath -BaseUrl $BaseUrl -ValidateOnly *> $null
    return $LASTEXITCODE
}

if ((Invoke-Validation 'https://liuhetong888.com') -ne 0) {
    throw 'approved HTTPS domain must validate'
}

foreach ($invalid in @(
    'http://liuhetong888.com',
    'https://localhost',
    'https://127.0.0.1',
    'https://192.168.1.116',
    'https://liuhetong888.com/api/v1'
)) {
    if ((Invoke-Validation $invalid) -eq 0) {
        throw "unsafe public mobile URL was accepted: $invalid"
    }
}

$content = Get-Content -LiteralPath $scriptPath -Raw -Encoding UTF8
if ($content -notmatch 'LIUHETONG_BUSINESS_API_URL') {
    throw 'Business API dart-define is required'
}
if ($content -notmatch 'LIUHETONG_MATRIX_HOMESERVER') {
    throw 'Matrix dart-define is required'
}

Write-Output 'Mobile public-domain build policy: PASS'
