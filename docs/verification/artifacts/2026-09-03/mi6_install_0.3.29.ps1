# 点开下载项 → 处理 MIUI 安装确认 → 验证升级到 0.3.29
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$adb = 'C:\Users\Administrator\AppData\Local\Android\sdk\platform-tools\adb.exe'
$device = 'cbd0156b'

# 下载项在列表第一行（约 y 300-420）
& $adb -s $device shell input tap 540 350
Start-Sleep -Seconds 4

for ($i = 1; $i -le 8; $i++) {
  & $adb -s $device shell uiautomator dump /sdcard/window_dump.xml 2>$null | Out-Null
  $raw = [string]::Join([char]10, (& $adb -s $device exec-out cat /sdcard/window_dump.xml 2>$null))
  $xml = $null
  try { $xml = [xml]$raw } catch {}
  $labels = @()
  if ($xml) {
    foreach ($n in $xml.SelectNodes('//node')) {
      $d = $n.GetAttribute('content-desc'); $t = $n.GetAttribute('text')
      if ($d -and $d.Trim()) { $labels += $d }
      elseif ($t -and $t.Trim()) { $labels += $t }
    }
  }
  Write-Output ("round $i labels: " + (($labels | Select-Object -First 8) -join ' / '))
  # MIUI 安装确认按钮
  foreach ($needle in @('安装', '继续安装', '确定')) {
    $hit = $labels -contains $needle
    if ($hit) {
      & $adb -s $device shell input keyevent KEYCODE_ENTER
      # 用 monkey 无法点系统按钮；改用 tap：找按钮 bounds
      break
    }
  }
  $ver = & $adb -s $device shell dumpsys package com.liuhetong.mobile | Select-String -Pattern 'versionName=' | Select-Object -First 1
  Write-Output "  version: $ver"
  if ("$ver".Contains('0.3.29')) { Write-Output 'UPGRADED'; exit 0 }
  Start-Sleep -Seconds 8
}
