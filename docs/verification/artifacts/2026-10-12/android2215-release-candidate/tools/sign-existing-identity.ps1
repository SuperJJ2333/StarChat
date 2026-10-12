#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][Alias('Input')][string]$InputApk,
    [Parameter(Mandatory)][Alias('Output')][string]$OutputApk,
    [Parameter(Mandatory)][string]$Apksigner,
    [switch]$Execute
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$taskUtf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $taskUtf8
[Console]::OutputEncoding = $taskUtf8
$OutputEncoding = $taskUtf8
$env:PYTHONUTF8 = '1'
$env:PYTHONIOENCODING = 'utf-8'

function Get-SafeLocalPath {
    param([string]$Path, [ValidateSet('File', 'NewFile')][string]$Kind)
    # SDK apksigner.bat crosses cmd.exe; refuse expansion/metacharacters before secret access.
    if ($Path -match '[%!&|<>^"\r\n]') { throw 'Shell metacharacters are not accepted in paths.' }
    if (-not [IO.Path]::IsPathFullyQualified($Path)) { throw 'Absolute path required.' }
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.StartsWith('\\') -or $full.Substring([IO.Path]::GetPathRoot($full).Length).Contains(':')) {
        throw 'Only ordinary local filesystem paths are accepted.'
    }
    if ($Kind -eq 'File' -and -not (Test-Path -LiteralPath $full -PathType Leaf)) { throw 'Required file missing.' }
    if ($Kind -eq 'NewFile' -and (Test-Path -LiteralPath $full)) { throw 'Output already exists.' }
    $parent = [IO.Path]::GetDirectoryName($full)
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw 'Output directory missing.' }
    $cursor = if ($Kind -eq 'File') { $full } else { $parent }
    while ($cursor) {
        $item = Get-Item -LiteralPath $cursor -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Linked paths are not accepted.' }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
    return $full
}

function Assert-ApkVerification {
    param([string[]]$Lines)
    $expected = '75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff'
    $digests = @($Lines | Where-Object { $_ -match '^Signer #[0-9]+ certificate SHA-256 digest: ' })
    if ($digests.Count -ne 1 -or $digests[0] -cne "Signer #1 certificate SHA-256 digest: $expected") { throw 'Certificate verification failed.' }
    $required = @(
        '^Verifies$',
        '^Number of signers: 1$',
        '^Signer #1 key algorithm: RSA$',
        '^Signer #1 key size \(bits\): 3072$',
        '^Verified using v2 scheme \(APK Signature Scheme v2\): true$',
        '^Verified using v3 scheme \(APK Signature Scheme v3\): true$'
    )
    foreach ($pattern in $required) {
        if (@($Lines | Where-Object { $_ -cmatch $pattern }).Count -ne 1) { throw 'Signature verification failed.' }
    }
    if (@($Lines | Where-Object { $_ -match '^Number of signers:' }).Count -ne 1) { throw 'Ambiguous signature verification.' }
}

$taskStage = 'path preflight'
$taskPassword = $null
$taskSecurePassword = $null
$taskPasswordPointer = [IntPtr]::Zero
$taskPasswordEnvironmentName = $null
$taskCertificates = $null
$taskPublicKey = $null
$taskTemporaryApk = $null
$taskToolOutput = $null
try {
    if (-not $IsWindows) { throw 'Windows DPAPI is required.' }
    $taskInput = Get-SafeLocalPath -Path $InputApk -Kind File
    $taskOutput = [IO.Path]::GetFullPath($OutputApk)
    if ([string]::Equals($taskInput, $taskOutput, [StringComparison]::OrdinalIgnoreCase)) { throw 'Input and output must differ.' }
    $taskOutput = Get-SafeLocalPath -Path $OutputApk -Kind NewFile
    $taskSigner = Get-SafeLocalPath -Path $Apksigner -Kind File
    if ([IO.Path]::GetExtension($taskInput) -ine '.apk' -or [IO.Path]::GetExtension($taskOutput) -ine '.apk') { throw 'APK paths required.' }
    $taskIdentityDirectory = Join-Path $env:USERPROFILE '.chatflow-signing/diagnostic-20260905'
    $taskKeystore = Get-SafeLocalPath -Path (Join-Path $taskIdentityDirectory 'diagnostic.p12') -Kind File
    $taskDpapi = Get-SafeLocalPath -Path (Join-Path $taskIdentityDirectory 'password.dpapi') -Kind File
    if ((Get-Item -LiteralPath $taskInput).Length -eq 0 -or (Get-Item -LiteralPath $taskKeystore).Length -eq 0 -or (Get-Item -LiteralPath $taskDpapi).Length -eq 0) { throw 'Empty required file.' }
    $taskExpectedCertificate = '75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff'
    $taskAlias = 'chatflow-local-ab-20260905'
    $taskInputSha = (Get-FileHash -LiteralPath $taskInput -Algorithm SHA256).Hash.ToLowerInvariant()
    if (-not $Execute) {
        [ordered]@{
            status = 'PLAN_ONLY'; mode = 'plan'; execute_required = $true
            input = $taskInput; input_sha256 = $taskInputSha; output = $taskOutput
            apksigner = $taskSigner; alias = $taskAlias; certificate_sha256 = $taskExpectedCertificate
            password_read = $false; signing_executed = $false
        } | ConvertTo-Json -Depth 3
        return
    }

    $taskStage = 'protected identity loading'
    $taskSecurePassword = (Get-Content -LiteralPath $taskDpapi -Raw -Encoding utf8).Trim() | ConvertTo-SecureString
    $taskPasswordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($taskSecurePassword)
    $taskPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($taskPasswordPointer)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($taskPasswordPointer)
    $taskPasswordPointer = [IntPtr]::Zero
    if ([string]::IsNullOrEmpty($taskPassword)) { throw 'Empty protected password.' }
    $taskCertificates = [Security.Cryptography.X509Certificates.X509Certificate2Collection]::new()
    $taskCertificates.Import($taskKeystore, $taskPassword, [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)
    $taskPrivateCertificates = @($taskCertificates | Where-Object HasPrivateKey)
    if ($taskPrivateCertificates.Count -ne 1) { throw 'Expected exactly one signing identity.' }
    $taskCertificate = $taskPrivateCertificates[0]
    $taskActualCertificate = $taskCertificate.GetCertHashString([Security.Cryptography.HashAlgorithmName]::SHA256).ToLowerInvariant()
    if ($taskActualCertificate -cne $taskExpectedCertificate) { throw 'Unexpected signing identity.' }
    $taskPublicKey = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($taskCertificate)
    if ($null -eq $taskPublicKey -or $taskPublicKey.KeySize -ne 3072) { throw 'Unexpected signing key.' }

    $taskStage = 'APK signing'
    $taskPasswordEnvironmentName = 'CHATFLOW_APK_SIGN_PASSWORD_' + [Guid]::NewGuid().ToString('N')
    [Environment]::SetEnvironmentVariable($taskPasswordEnvironmentName, $taskPassword, 'Process')
    $taskTemporaryApk = Join-Path ([IO.Path]::GetDirectoryName($taskOutput)) ('.' + [IO.Path]::GetFileNameWithoutExtension($taskOutput) + '.signing-' + [Guid]::NewGuid().ToString('N') + '.apk')
    if (Test-Path -LiteralPath $taskTemporaryApk) { throw 'Temporary path collision.' }
    $taskSignArguments = @(
        'sign', '--ks', $taskKeystore, '--ks-type', 'PKCS12', '--ks-key-alias', $taskAlias,
        '--ks-pass', ('env:' + $taskPasswordEnvironmentName), '--key-pass', ('env:' + $taskPasswordEnvironmentName),
        '--v1-signing-enabled', 'false', '--v2-signing-enabled', 'true', '--v3-signing-enabled', 'true',
        '--v4-signing-enabled', 'false', '--out', $taskTemporaryApk, $taskInput
    )
    $taskToolOutput = @(& $taskSigner @taskSignArguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw 'APK signing failed.' }
    # Tool output is deliberately never forwarded: even unexpected diagnostics may contain credentials.
    $taskToolOutput = $null
    [Environment]::SetEnvironmentVariable($taskPasswordEnvironmentName, $null, 'Process')
    $taskPassword = $null

    $taskStage = 'signed APK verification'
    $taskToolOutput = @(& $taskSigner verify --verbose --print-certs $taskTemporaryApk 2>&1)
    if ($LASTEXITCODE -ne 0) { throw 'APK verification failed.' }
    Assert-ApkVerification -Lines @($taskToolOutput | ForEach-Object { $_.ToString() })
    $taskToolOutput = $null
    if ((Get-FileHash -LiteralPath $taskInput -Algorithm SHA256).Hash.ToLowerInvariant() -cne $taskInputSha) { throw 'Input changed during signing.' }
    $null = Get-SafeLocalPath -Path $taskTemporaryApk -Kind File
    $null = Get-SafeLocalPath -Path $taskOutput -Kind NewFile
    $taskOutputSha = (Get-FileHash -LiteralPath $taskTemporaryApk -Algorithm SHA256).Hash.ToLowerInvariant()
    $taskOutputBytes = (Get-Item -LiteralPath $taskTemporaryApk).Length
    $taskStage = 'atomic output publication'
    [IO.File]::Move($taskTemporaryApk, $taskOutput, $false)
    $taskTemporaryApk = $null
    [ordered]@{
        status = 'SIGNED_AND_VERIFIED'; mode = 'execute'; execute_required = $false
        input = $taskInput; input_sha256 = $taskInputSha; output = $taskOutput
        output_sha256 = $taskOutputSha; output_bytes = $taskOutputBytes
        alias = $taskAlias; certificate_sha256 = $taskExpectedCertificate
        signature_v2 = $true; signature_v3 = $true; signing_executed = $true
    } | ConvertTo-Json -Depth 3
}
catch {
    [Console]::Error.WriteLine("Signing wrapper failed at $taskStage; sensitive tool diagnostics suppressed.")
    exit 1
}
finally {
    if ($taskPasswordEnvironmentName) { [Environment]::SetEnvironmentVariable($taskPasswordEnvironmentName, $null, 'Process') }
    if ($taskPasswordPointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($taskPasswordPointer) }
    if ($taskSecurePassword) { $taskSecurePassword.Dispose() }
    if ($taskPublicKey) { $taskPublicKey.Dispose() }
    if ($taskCertificates) { foreach ($taskDisposableCertificate in $taskCertificates) { $taskDisposableCertificate.Dispose() } }
    $taskPassword = $null
    $taskToolOutput = $null
    if ($taskTemporaryApk -and (Test-Path -LiteralPath $taskTemporaryApk)) { [IO.File]::Delete($taskTemporaryApk) }
}
