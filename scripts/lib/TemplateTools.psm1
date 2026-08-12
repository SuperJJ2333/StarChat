function Expand-StrictTemplate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Content,

        [Parameter(Mandatory)]
        [hashtable]$Variables
    )

    foreach ($key in $Variables.Keys) {
        $token = '{{' + [string]$key + '}}'
        $Content = $Content.Replace($token, [string]$Variables[$key])
    }

    $unresolved = [regex]::Matches($Content, '\{\{[A-Z][A-Z0-9_]*\}\}')
    if ($unresolved.Count -gt 0) {
        $names = $unresolved.Value | Sort-Object -Unique
        throw "Unresolved template tokens: $($names -join ', ')"
    }

    return $Content
}

function Write-RenderedTemplate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TemplatePath,

        [Parameter(Mandatory)]
        [string]$DestinationPath,

        [Parameter(Mandatory)]
        [hashtable]$Variables
    )

    $content = Get-Content -LiteralPath $TemplatePath -Raw -Encoding UTF8
    $rendered = Expand-StrictTemplate -Content $content -Variables $Variables

    $destinationDirectory = Split-Path -Parent $DestinationPath
    if (-not (Test-Path -LiteralPath $destinationDirectory)) {
        New-Item -ItemType Directory -Path $destinationDirectory | Out-Null
    }

    Set-Content -LiteralPath $DestinationPath -Value $rendered -NoNewline -Encoding utf8NoBOM
}

Export-ModuleMember -Function Expand-StrictTemplate, Write-RenderedTemplate
