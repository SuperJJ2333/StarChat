param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9.-]+$')]
    [string]$RootDomain,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9.-]+$')]
    [string]$WwwDomain,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9.-]+$')]
    [string]$AdminDomain
)

$ErrorActionPreference = 'Stop'
$failures = [System.Collections.Generic.List[string]]::new()

function Add-Failure([string]$Message) {
    $script:failures.Add($Message)
    Write-Host "FAIL: $Message"
}

function Test-Dns([string]$Domain) {
    try {
        $records = @(Resolve-DnsName -Name $Domain -Type A -DnsOnly)
        if (-not ($records | Where-Object IPAddress)) {
            Add-Failure "$Domain has no IPv4 address"
            return
        }
        Write-Host "PASS: DNS $Domain"
    }
    catch {
        Add-Failure "DNS $Domain - $($_.Exception.Message)"
    }
}

function Get-Response([string]$Uri) {
    try {
        return Invoke-WebRequest -Uri $Uri -MaximumRedirection 0 `
            -SkipHttpErrorCheck -TimeoutSec 15
    }
    catch {
        Add-Failure "$Uri - $($_.Exception.Message)"
        return $null
    }
}

function Assert-Status([string]$Uri, [int[]]$Expected) {
    $response = Get-Response $Uri
    if ($null -eq $response) { return $null }
    if ([int]$response.StatusCode -notin $Expected) {
        Add-Failure "$Uri returned $([int]$response.StatusCode), expected $($Expected -join '/')"
        return $response
    }
    Write-Host "PASS: $Uri [$([int]$response.StatusCode)]"
    return $response
}

foreach ($domain in @($RootDomain, $WwwDomain, $AdminDomain)) {
    Test-Dns $domain
}

$httpRoot = Assert-Status "http://$RootDomain/" @(301, 308)
if ($httpRoot -and $httpRoot.Headers.Location -ne "https://$RootDomain/") {
    Add-Failure "HTTP root redirect target is $($httpRoot.Headers.Location)"
}

$httpWww = Assert-Status "http://$WwwDomain/domain-check?source=www" @(301, 308)
if ($httpWww -and $httpWww.Headers.Location -ne "https://$RootDomain/domain-check?source=www") {
    Add-Failure "HTTP www redirect does not preserve path and query"
}

$httpsWww = Assert-Status "https://$WwwDomain/domain-check?source=www" @(301, 308)
if ($httpsWww -and $httpsWww.Headers.Location -ne "https://$RootDomain/domain-check?source=www") {
    Add-Failure "HTTPS www redirect does not preserve path and query"
}

Assert-Status "https://$RootDomain/api/v1/health/live" @(200) | Out-Null
Assert-Status "https://$RootDomain/api/v1/health/ready" @(200) | Out-Null
Assert-Status "https://$RootDomain/_matrix/client/versions" @(200) | Out-Null

$wellKnown = Assert-Status "https://$RootDomain/.well-known/matrix/client" @(200)
if ($wellKnown) {
    try {
        $document = $wellKnown.Content | ConvertFrom-Json
        $baseUrl = $document.'m.homeserver'.base_url
        if ($baseUrl.TrimEnd('/') -ne "https://$RootDomain") {
            Add-Failure "Matrix discovery base_url is $baseUrl"
        }
        else {
            Write-Host 'PASS: Matrix discovery base_url'
        }
    }
    catch {
        Add-Failure "Matrix discovery JSON is invalid - $($_.Exception.Message)"
    }
}

Assert-Status "https://$AdminDomain/api/v1/health/live" @(200) | Out-Null
Assert-Status "https://$AdminDomain/" @(404) | Out-Null
Assert-Status "https://$RootDomain/_synapse/admin/v1/server_version" @(404) | Out-Null
Assert-Status "https://$AdminDomain/_synapse/admin/v1/server_version" @(404) | Out-Null

if ($failures.Count -gt 0) {
    Write-Output "Public domain verification: FAIL ($($failures.Count) checks)"
    exit 1
}

Write-Output 'Public domain verification: PASS'
