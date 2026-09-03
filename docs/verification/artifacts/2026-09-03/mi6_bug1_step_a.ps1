# BUG1 取证 Step A：进入通讯录，输出联系人列表语义标签 + 消息页基线
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)

$adb = 'C:\Users\Administrator\AppData\Local\Android\sdk\platform-tools\adb.exe'
$device = 'cbd0156b'

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
function Find-CenterByDesc([xml]$x, [string]$needle) {
  foreach ($n in $x.SelectNodes('//node')) {
    $d = $n.GetAttribute('content-desc')
    $t = $n.GetAttribute('text')
    if (($d -and $d.Contains($needle)) -or ($t -and $t.Contains($needle))) {
      $b = $n.GetAttribute('bounds')
      if ($b -match '\[(\d+),(\d+)\]\[(\d+),(\d+)\]') {
        $cx = ([int]$Matches[1] + [int]$Matches[3]) / 2
        $cy = ([int]$Matches[2] + [int]$Matches[4]) / 2
        return @([int]$cx, [int]$cy)
      }
    }
  }
  return $null
}

& $adb -s $device shell input keyevent KEYCODE_WAKEUP | Out-Null
Start-Sleep -Seconds 1
& $adb -s $device shell monkey -p com.liuhetong.mobile -c android.intent.category.LAUNCHER 1 | Out-Null
Start-Sleep -Seconds 8

Write-Output '=== 消息页基线（前 12 条） ==='
$msg = Get-Dump
Show-Desc $msg 12

Write-Output ''
Write-Output '=== 进入通讯录 ==='
$tab = Find-CenterByDesc $msg '通讯录, 第 2 个标签'
if ($null -eq $tab) { Write-Output '!! 未找到通讯录 tab'; exit 1 }
& $adb -s $device shell input tap $tab[0] $tab[1]
Start-Sleep -Seconds 4
$contacts = Get-Dump
Write-Output '=== 通讯录页语义节点（前 30） ==='
Show-Desc $contacts 30
