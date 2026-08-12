$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot '..\..\scripts\lib\TemplateTools.psm1'
Import-Module $modulePath -Force

function Assert-Equal {
    param(
        $Actual,
        $Expected,
        [string]$Message
    )

    if ($Actual -cne $Expected) {
        throw "$Message`nExpected: $Expected`nActual: $Actual"
    }
}

$rendered = Expand-StrictTemplate `
    -Content 'server_name: "{{MATRIX_SERVER_NAME}}"' `
    -Variables @{ MATRIX_SERVER_NAME = 'matrix.localhost' }
Assert-Equal $rendered 'server_name: "matrix.localhost"' 'double-brace token replacement failed'

$json = Expand-StrictTemplate `
    -Content '{"base_url":"{{BASE_URL}}"}' `
    -Variables @{ BASE_URL = 'https://chat.example.test/' }
$null = $json | ConvertFrom-Json
Assert-Equal $json '{"base_url":"https://chat.example.test/"}' 'JSON rendering failed'

$threw = $false
try {
    Expand-StrictTemplate -Content '{{MISSING}}' -Variables @{}
}
catch {
    $threw = $true
}

if (-not $threw) {
    throw 'unresolved tokens must fail'
}

Write-Output 'TemplateTools: PASS'
