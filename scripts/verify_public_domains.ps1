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

function Get-Response([string]$Uri, [string]$Method = 'GET') {
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(15)
    try {
        $response = if ($Method -eq 'HEAD') {
            $client.SendAsync([System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Head, $Uri)).GetAwaiter().GetResult()
        }
        else {
            $client.GetAsync($Uri).GetAwaiter().GetResult()
        }
        $location = if ($null -ne $response.Headers.Location) {
            $response.Headers.Location.ToString()
        }
        else {
            $null
        }
        return [pscustomobject]@{
            StatusCode = [int]$response.StatusCode
            Headers = [pscustomobject]@{ Location = $location }
            Content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        }
    }
    catch {
        Add-Failure "$Uri - $($_.Exception.Message)"
        return $null
    }
    finally {
        $client.Dispose()
        $handler.Dispose()
    }
}

function Assert-Status([string]$Uri, [int[]]$Expected, [string]$Method = 'GET') {
    $response = Get-Response $Uri $Method
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

# www serves the product landing page (and the Android download path).
$repoRoot = Split-Path -Parent $PSScriptRoot
$pubspec = Get-Content -LiteralPath (Join-Path $repoRoot 'apps/mobile_flutter/pubspec.yaml') -Raw -Encoding UTF8
if ($pubspec -notmatch '(?m)^version:\s*(\d+\.\d+\.\d+)\+\d+\s*$') {
    Add-Failure 'pubspec.yaml must declare version: X.Y.Z+build'
}
$releaseVersion = $Matches[1]
$apkUrl = "https://$WwwDomain/downloads/latest-arm64.apk"

$landing = Assert-Status "https://$WwwDomain/" @(200)
if ($landing) {
    foreach ($needle in @('畅聊 ChatFlow', '/downloads/latest-arm64.apk')) {
        if (-not $landing.Content.Contains($needle)) {
            Add-Failure "www landing page does not mention '$needle'"
        }
    }
    if ($landing.Content) { Write-Host 'PASS: www landing page content' }
}

$apk = Assert-Status $apkUrl @(200) 'HEAD'
if ($apk) {
    Write-Host "PASS: www APK download head [$([int]$apk.StatusCode)]"
}
foreach ($variant in @('arm32', 'x86_64')) {
    $variantUrl = "https://$WwwDomain/downloads/latest-$variant.apk"
    Assert-Status $variantUrl @(200) 'HEAD' | Out-Null
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
Assert-Status "https://$AdminDomain/" @(200) | Out-Null
Assert-Status "https://$RootDomain/_synapse/admin/v1/server_version" @(404) | Out-Null
Assert-Status "https://$AdminDomain/_synapse/admin/v1/server_version" @(404) | Out-Null

if ($failures.Count -gt 0) {
    Write-Output "Public domain verification: FAIL ($($failures.Count) checks)"
    exit 1
}

Write-Output 'Public domain verification: PASS'
