# BUG1 修复验证（续）：好友行(510,867) → 好友资料 → 发消息 → 判定
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$adb = 'C:\Users\Administrator\AppData\Local\Android\sdk\platform-tools\adb.exe'
$device = 'cbd0156b'
$art = 'D:\pythonProject\outsource\StarChat\docs\verification\artifacts\2026-09-03'

function Get-Labels {
  & $adb -s $device shell uiautomator dump /sdcard/window_dump.xml | Out-Null
  $xml = [xml]([string]::Join([char]10, (& $adb -s $device exec-out cat /sdcard/window_dump.xml)))
  $out = @()
  foreach ($n in $xml.SelectNodes('//node')) {
    $d = $n.GetAttribute('content-desc'); $t = $n.GetAttribute('text')
    $label = if ($d -and $d.Trim()) { $d } elseif ($t -and $t.Trim()) { $t } else { $null }
    if ($label) { $out += [pscustomobject]@{Label=$label; Bounds=$n.GetAttribute('bounds'); Click=$n.GetAttribute('clickable')} }
  }
  return ,$out
}
function Tap-Label($labels, [string]$needle) {
  foreach ($l in $labels) {
    if ($l.Label.Contains($needle) -and $l.Bounds -match '\[(\d+),(\d+)\]\[(\d+),(\d+)\]') {
      $cx = ([int]$Matches[1] + [int]$Matches[3]) / 2
      $cy = ([int]$Matches[2] + [int]$Matches[4]) / 2
      & $adb -s $device shell input tap $([int]$cx) $([int]$cy)
      return $true
    }
  }
  return $false
}
function Snap([string]$name) {
  & $adb -s $device exec-out screencap -p > "$art\$name"
  Write-Output "saved $name"
}

# 进入好友资料页
& $adb -s $device shell input tap 510 867
Start-Sleep -Seconds 3
Snap 'bug1v-3-profile.png'
$labels = Get-Labels
Write-Output ('好友资料 title: ' + [bool]($labels | Where-Object { $_.Label -eq '好友资料' }))
$btn = $labels | Where-Object { $_.Label -eq '发消息' } | Select-Object -First 1
if (-not $btn) { Write-Output ('profile labels: ' + (($labels | ForEach-Object { $_.Label }) -join ' / ')); exit 1 }
Write-Output ('发消息 bounds: ' + $btn.Bounds)

# 点发消息
if ($btn.Bounds -match '\[(\d+),(\d+)\]\[(\d+),(\d+)\]') {
  $cx = ([int]$Matches[1] + [int]$Matches[3]) / 2
  $cy = ([int]$Matches[2] + [int]$Matches[4]) / 2
  & $adb -s $device shell input tap $([int]$cx) $([int]$cy)
}
Start-Sleep -Seconds 14
Snap 'bug1v-4-after.png'
$after = Get-Labels
Write-Output '--- 结果判定 ---'
$dialog = $after | Where-Object { $_.Label.Contains('无法打开加密会话') }
if ($dialog) { Write-Output 'FAIL: 错误弹窗仍存在' } else { Write-Output 'OK: 无“无法打开加密会话”弹窗' }
Write-Output ('聊天工具栏(语音消息): ' + [bool]($after | Where-Object { $_.Label -eq '语音消息' }))
Write-Output ('after labels: ' + (($after | Select-Object -First 12 | ForEach-Object { $_.Label }) -join ' / '))
