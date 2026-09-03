# 0.3.29 更新弹窗验证（Mi 6 当前 0.3.28/2031 < 2032 应弹窗）
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$adb = 'C:\Users\Administrator\AppData\Local\Android\sdk\platform-tools\adb.exe'
$device = 'cbd0156b'
$art = 'D:\pythonProject\outsource\StarChat\docs\verification\artifacts\2026-09-03'

& $adb -s $device shell input keyevent KEYCODE_WAKEUP | Out-Null
Start-Sleep -Seconds 1
& $adb -s $device shell am force-stop com.liuhetong.mobile
Start-Sleep -Seconds 2
& $adb -s $device shell monkey -p com.liuhetong.mobile -c android.intent.category.LAUNCHER 1 | Out-Null
Start-Sleep -Seconds 12

& $adb -s $device shell uiautomator dump /sdcard/window_dump.xml | Out-Null
$xml = [xml]([string]::Join([char]10, (& $adb -s $device exec-out cat /sdcard/window_dump.xml)))
$labels = @()
foreach ($n in $xml.SelectNodes('//node')) {
  $d = $n.GetAttribute('content-desc'); $t = $n.GetAttribute('text')
  $label = if ($d -and $d.Trim()) { $d } elseif ($t -and $t.Trim()) { $t } else { $null }
  if ($label) { $labels += $label }
}
Write-Output ('发现新版本: ' + ($labels -match '发现新版本').Count)
Write-Output ('0.3.29 出现: ' + ($labels -match '0.3.29').Count)
Write-Output ('更新按钮: ' + ($labels -match '更新').Count)
& $adb -s $device exec-out screencap -p > "$art\mi6-update-popup-0.3.29.png"
Write-Output 'saved mi6-update-popup-0.3.29.png'
Write-Output ('labels: ' + (($labels | Select-Object -First 14) -join ' / '))
