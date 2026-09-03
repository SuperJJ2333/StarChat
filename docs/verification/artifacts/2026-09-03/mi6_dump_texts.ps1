# Mi 6 屏幕文本提取：确认消息页已渲染真实内容（而非加载动画）
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)

$adb = 'C:\Users\Administrator\AppData\Local\Android\sdk\platform-tools\adb.exe'
$device = 'cbd0156b'

Write-Output '--- app_home.dart fallback marker ---'
$homePath = 'D:\pythonProject\outsource\StarChat\apps\mobile_flutter\lib\app_home.dart'
Select-String -LiteralPath $homePath -Pattern 'ProfileRepository\(widget\.api', 'SharedPreferencesProfileStore' |
  ForEach-Object { '{0}: {1}' -f $_.LineNumber, $_.Line.Trim() }

Write-Output ''
Write-Output '--- foreground activity ---'
& $adb -s $device shell dumpsys activity activities | Select-String 'mResumedActivity'

Write-Output ''
Write-Output '--- visible texts on screen ---'
$xml = [string]::Join([char]10, (& $adb -s $device exec-out cat /sdcard/window_dump.xml))
([regex]::Matches($xml, 'text="([^"]{1,40})"') | ForEach-Object { $_.Groups[1].Value } |
  Where-Object { $_.Trim().Length -gt 0 } | Select-Object -Unique -First 25)
