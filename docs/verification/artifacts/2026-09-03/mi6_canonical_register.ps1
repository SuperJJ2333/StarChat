# BUG1 验证：通讯录 → 这个小鸿 → 发消息（触发 canonical 注册）
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$adb = 'C:\Users\Administrator\AppData\Local\Android\sdk\platform-tools\adb.exe'
$device = 'cbd0156b'

function Get-Labels {
  & $adb -s $device shell uiautomator dump /sdcard/window_dump.xml | Out-Null
  $xml = [xml]([string]::Join([char]10, (& $adb -s $device exec-out cat /sdcard/window_dump.xml)))
  $out = @()
  foreach ($n in $xml.SelectNodes('//node')) {
    $d = $n.GetAttribute('content-desc'); $t = $n.GetAttribute('text')
    $label = if ($d -and $d.Trim()) { $d } elseif ($t -and $t.Trim()) { $t } else { $null }
    if ($label) { $out += [pscustomobject]@{Label=$label; Bounds=$n.GetAttribute('bounds')} }
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

$labels = Get-Labels
if (-not (Tap-Label $labels '通讯录, 第 2 个标签')) { Write-Output '!! 通讯录 tab 未找到'; exit 1 }
Start-Sleep -Seconds 4
$labels = Get-Labels
if (-not (Tap-Label $labels '这个小鸿')) { Write-Output '!! 联系人行未找到'; exit 1 }
Start-Sleep -Seconds 3
$labels = Get-Labels
if (-not (Tap-Label $labels '发消息')) { Write-Output '!! 发消息按钮未找到'; exit 1 }
Write-Output 'tapped 发消息, waiting for room open + canonical register...'
Start-Sleep -Seconds 15
$labels = Get-Labels
$dialog = $labels | Where-Object { $_.Label.Contains('无法打开加密会话') }
if ($dialog) { Write-Output 'FAIL: 错误弹窗存在' } else { Write-Output 'OK: 已进入聊天页（无错误弹窗）' }
Write-Output ('在聊天页: ' + [bool]($labels | Where-Object { $_.Label -eq '语音消息' }))
# 返回桌面（保持进程存活，触发后台通知场景）
& $adb -s $device shell input keyevent KEYCODE_HOME
Start-Sleep -Seconds 2
Write-Output 'sent HOME (app backgrounded, process alive via FGS)'
