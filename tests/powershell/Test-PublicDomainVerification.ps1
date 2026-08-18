$ErrorActionPreference = 'Stop'

$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$scriptPath = Join-Path $root 'scripts\verify_public_domains.ps1'

if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw 'public domain verification script is required'
}

$content = Get-Content -LiteralPath $scriptPath -Raw -Encoding UTF8

function Assert-Match([string]$Pattern, [string]$Message) {
    if ($content -notmatch $Pattern) { throw $Message }
}

Assert-Match 'Resolve-DnsName' 'DNS verification is required'
Assert-Match '/api/v1/health/live' 'Business live check is required'
Assert-Match '/api/v1/health/ready' 'Business ready check is required'
Assert-Match '/_matrix/client/versions' 'Matrix versions check is required'
Assert-Match '/\.well-known/matrix/client' 'Matrix discovery check is required'
Assert-Match 'WwwDomain' 'www redirect check is required'
Assert-Match 'AdminDomain' 'admin API check is required'

if ($content -match 'SkipCertificateCheck|--insecure|-k(?:\s|$)') {
    throw 'TLS verification must never be bypassed'
}

Write-Output 'Public domain verification structure: PASS'
