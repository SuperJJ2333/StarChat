# BUG1 修复验证：通讯录 → 好友头像 → 好友资料 → 发消息 → 应进入聊天（无错误弹窗）
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)

$adb = 'C:\Users\Administrator\AppData\Local\Android\sdk\platform-tools\adb.exe'
$device = 'cbd0156b'
$art = 'D:\pythonProject\outsource\StarChat\docs\verification\artifacts\2026-09-03'

function Get-Dump {
  & $adb -s $device shell uiautomator dump /sdcard/window_dump.xml | Out-Null
  return [string]::Join([char]10, (& $adb -s $device exec-out cat /sdcard/window_dump.xml))
}
function Find-Bounds([string]$xml, [string]$needle) {
  foreach ($m in [regex]::Matches($xml, '<node[^>]*content-desc="([^"]{0,120})"[^>]*bounds="(\[\d+,\d+\]\[\d+,\d+\])"')) {
    if ($m.Groups[1].Value.Contains($needle)) { return $m.Groups[2].Value }
  }
  return $null
}
function Tap-Bounds([string]$b) {
  if ($b -match '\[(\d+),(\d+)\]\[(\d+),(\d+)\]') {
    $cx = ([int]$Matches[1] + [int]$Matches[3]) / 2
    $cy = ([int]$Matches[2] + [int]$Matches[4]) / 2
    & $adb -s $device shell input tap $([int]$cx) $([int]$cy)
    return $true
  }
  return $false
}
function Snap([string]$name) {
  & $adb -s $device exec-out screencap -p > "$art\$name"
  Write-Output "saved $name"
}

& $adb -s $device shell input keyevent KEYCODE_WAKEUP | Out-Null
Start-Sleep -Seconds 1
& $adb -s $device shell am force-stop com.liuhetong.mobile
Start-Sleep -Seconds 2
& $adb -s $device shell monkey -p com.liuhetong.mobile -c android.intent.category.LAUNCHER 1 | Out-Null
Start-Sleep -Seconds 10
Snap 'bug1v-1-home.png'

# 通讯录 tab
$xml = Get-Dump
$tab = Find-Bounds $xml '通讯录, 第 2 个标签'
if (-not $tab) { Write-Output '!! 未找到通讯录 tab'; exit 1 }
Tap-Bounds $tab | Out-Null
Start-Sleep -Seconds 4
Snap 'bug1v-2-contacts.png'
$xml = Get-Dump
Write-Output ('contacts page contains 新的朋友: ' + $xml.Contains('新的朋友'))
Write-Output ('contacts page contains 群聊: ' + $xml.Contains('群聊'))

# 第一个联系人行（整行可点：点击行中心）
$rowMatch = $null
foreach ($m in [regex]::Matches($xml, 'bounds="(\[36,\d+\]\[1044,\d+\])"')) { $rowMatch = $m.Groups[1].Value; break }
if (-not $rowMatch) {
  foreach ($m in [regex]::Matches($xml, '<node[^>]*content-desc="([^"]{1,40})"[^>]*bounds="(\[\d+,\d+\]\[\d+,\d+\])"')) {
    if ($m.Groups[1].Value.Trim().Length -gt 0) { $rowMatch = $m.Groups[2].Value; break }
  }
}
if (-not $rowMatch) { Write-Output '!! 未找到联系人行'; exit 1 }
Write-Output "first row bounds: $rowMatch"
Tap-Bounds $rowMatch | Out-Null
Start-Sleep -Seconds 3
Snap 'bug1v-3-profile.png'
$xml = Get-Dump
Write-Output ('profile page 好友资料: ' + $xml.Contains('好友资料'))
Write-Output ('profile page 发消息: ' + $xml.Contains('发消息'))

# 发消息
$btn = Find-Bounds $xml '发消息'
if (-not $btn) { Write-Output '!! 未找到发消息按钮'; exit 1 }
Tap-Bounds $btn | Out-Null
Start-Sleep -Seconds 12
Snap 'bug1v-4-after-message.png'
$xml = Get-Dump
Write-Output ('--- 结果判定 ---')
Write-Output ('错误弹窗 无法打开加密会话: ' + $(if ($xml.Contains('无法打开加密会话')) { 'PRESENT (BUG 仍存在)' } else { 'ABSENT (OK)' }))
Write-Output ('聊天工具栏 语音消息: ' + $xml.Contains('语音消息'))
Write-Output ('聊天工具栏 表情: ' + $xml.Contains('表情'))
Write-Output ('输入框/发送: ' + $(if ($xml.Contains('发送') -or $xml.Contains('消息')) { 'seen' } else { 'not seen' }))
