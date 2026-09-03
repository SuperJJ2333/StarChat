# 逐节点打印（XML 解析版）
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$adb = 'C:\Users\Administrator\AppData\Local\Android\sdk\platform-tools\adb.exe'
$device = 'cbd0156b'
& $adb -s $device shell uiautomator dump /sdcard/window_dump.xml | Out-Null
$xml = [xml]([string]::Join([char]10, (& $adb -s $device exec-out cat /sdcard/window_dump.xml)))
foreach ($n in $xml.SelectNodes('//node')) {
  $d = $n.GetAttribute('content-desc'); $t = $n.GetAttribute('text')
  $label = if ($d -and $d.Trim()) { $d } elseif ($t -and $t.Trim()) { $t } else { $null }
  if ($label) {
    '{0} | {1} | clickable={2}' -f $label, $n.GetAttribute('bounds'), $n.GetAttribute('clickable')
  }
}
