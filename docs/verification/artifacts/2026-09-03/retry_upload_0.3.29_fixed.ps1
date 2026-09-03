# 重试上传正确的 0.3.29 APK（SSH 限流恢复后自动完成）
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$apkDir = 'D:\pythonProject\outsource\StarChat\apps\mobile_flutter\build\app\outputs\flutter-apk'

$expected = @{
  'ChatFlow-0.3.29-arm64.apk'  = '129640AA608D5F2943927694019B09279055268C66A4CB0BF97DB2E4C694A4EB'
  'ChatFlow-0.3.29-arm32.apk'  = '9E72BEEB07B878F7B0F36F7A4BE1DD2B44A2C4CDC8307285B305F8641BF506B0'
  'ChatFlow-0.3.29-x86_64.apk' = '9C4B8AA3AE0BBEC8AE9F2B7B73FD874F28CD5E85327F828031FD60E2F71B83FB'
}

for ($attempt = 1; $attempt -le 40; $attempt++) {
  Write-Output "attempt $attempt $(Get-Date -Format HH:mm:ss)"
  ssh -o ConnectTimeout=12 liuhetong-prod 'echo ssh-ok' 2>$null
  if ($LASTEXITCODE -eq 0) {
    Write-Output 'SSH recovered, uploading...'
    Push-Location $apkDir
    scp ChatFlow-0.3.29-arm64.apk ChatFlow-0.3.29-arm32.apk ChatFlow-0.3.29-x86_64.apk liuhetong-prod:/opt/starchat/frontend/downloads/
    $scpOk = $?
    Pop-Location
    if ($scpOk) {
      $remote = ssh liuhetong-prod 'cd /opt/starchat/frontend/downloads && sha256sum ChatFlow-0.3.29-*.apk'
      Write-Output $remote
      $allOk = $true
      foreach ($name in $expected.Keys) {
        $line = $remote | Where-Object { $_ -match [regex]::Escape($name) }
        if (-not $line -or $line -notmatch $expected[$name]) { $allOk = $false; Write-Output "MISMATCH $name" }
      }
      Write-Output "UPLOAD_RESULT $(if ($allOk) { 'PASS' } else { 'FAIL' })"
      if ($allOk) { exit 0 }
    }
  }
  Start-Sleep -Seconds 60
}
Write-Output 'UPLOAD_RESULT TIMEOUT'
exit 1
