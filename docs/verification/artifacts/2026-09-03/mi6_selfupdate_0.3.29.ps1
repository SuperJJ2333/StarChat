# 0.3.29 应用内自升级验证
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$adb = 'C:\Users\Administrator\AppData\Local\Android\sdk\platform-tools\adb.exe'
$device = 'cbd0156b'

& $adb -s $device shell uiautomator dump /sdcard/window_dump.xml | Out-Null
$xml = [xml]([string]::Join([char]10, (& $adb -s $device exec-out cat /sdcard/window_dump.xml)))
foreach ($n in $xml.SelectNodes('//node')) {
  $d = $n.GetAttribute('content-desc'); $t = $n.GetAttribute('text')
  if (($d -eq '更新' -or $t -eq '更新') -and $n.GetAttribute('bounds') -match '\[(\d+),(\d+)\]\[(\d+),(\d+)\]') {
    $cx = ([int]$Matches[1] + [int]$Matches[3]) / 2
    $cy = ([int]$Matches[2] + [int]$Matches[4]) / 2
    & $adb -s $device shell input tap $([int]$cx) $([int]$cy)
    Write-Output "tapped 更新 at $cx,$cy"
    break
  }
}
for ($i = 1; $i -le 6; $i++) {
  Start-Sleep -Seconds 20
  $ver = & $adb -s $device shell dumpsys package com.liuhetong.mobile | Select-String -Pattern 'versionName=' | Select-Object -First 1
  Write-Output "check $i : $ver"
  if ("$ver".Contains('0.3.29')) { Write-Output 'UPGRADED'; break }
}
