# Mi 6 屏幕语义标签提取（Flutter 经 content-desc 暴露）
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)

$adb = 'C:\Users\Administrator\AppData\Local\Android\sdk\platform-tools\adb.exe'
$device = 'cbd0156b'

& $adb -s $device shell uiautomator dump /sdcard/window_dump.xml | Out-Null
$xml = [string]::Join([char]10, (& $adb -s $device exec-out cat /sdcard/window_dump.xml))
"xml length: $($xml.Length)"
$labels = [regex]::Matches($xml, 'content-desc="([^"]{1,60})"') |
  ForEach-Object { $_.Groups[1].Value } |
  Where-Object { $_.Trim().Length -gt 0 } |
  Select-Object -Unique -First 30
$labels
