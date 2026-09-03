# BUG1 取证 Step B：截图当前页 → 点第一个好友头像 → dump 好友资料页
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)

$adb = 'C:\Users\Administrator\AppData\Local\Android\sdk\platform-tools\adb.exe'
$device = 'cbd0156b'
$art = 'D:\pythonProject\outsource\StarChat\docs\verification\artifacts\2026-09-03'

function Get-Dump {
  & $adb -s $device shell uiautomator dump /sdcard/window_dump.xml | Out-Null
  return [xml]([string]::Join([char]10, (& $adb -s $device exec-out cat /sdcard/window_dump.xml)))
}
function Show-Desc([xml]$x, [int]$top = 40) {
  $i = 0
  foreach ($n in $x.SelectNodes('//node')) {
    $d = $n.GetAttribute('content-desc')
    $t = $n.GetAttribute('text')
    $b = $n.GetAttribute('bounds')
    $clickable = $n.GetAttribute('clickable')
    if (($d -and $d.Trim()) -or ($t -and $t.Trim())) {
      "[$i] desc=<$d> text=<$t> clickable=$clickable bounds=$b"
      $i++
      if ($i -ge $top) { break }
    }
  }
}

& $adb -s $device exec-out screencap -p > "$art\bug1-before-tap.png"
Write-Output 'screenshot saved: bug1-before-tap.png'

# 第一个好友行 [36,528][1044,828] → 头像区域取左部
& $adb -s $device shell input tap 168 678
Start-Sleep -Seconds 3
$profile = Get-Dump
Write-Output '=== 点击头像后页面（前 30） ==='
Show-Desc $profile 30
& $adb -s $device exec-out screencap -p > "$art\bug1-profile.png"
Write-Output 'screenshot saved: bug1-profile.png'
