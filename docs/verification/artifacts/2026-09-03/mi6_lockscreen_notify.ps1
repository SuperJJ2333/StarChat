# BUG2 验证：锁屏（息屏）状态下注入对方消息 → 验证系统通知
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$adb = 'C:\Users\Administrator\AppData\Local\Android\sdk\platform-tools\adb.exe'
$device = 'cbd0156b'

Write-Output '--- 1) 息屏（KEYCODE_SLEEP）---'
& $adb -s $device shell input keyevent KEYCODE_SLEEP
Start-Sleep -Seconds 3

Write-Output '--- 2) 远端注入消息（在服务器侧由调用方完成，此处等待） ---'
Write-Output 'waiting 15s for sync + notification...'
Start-Sleep -Seconds 15

Write-Output '--- 3) 唤醒（不解锁）并截图锁屏 ---'
& $adb -s $device shell input keyevent KEYCODE_WAKEUP
Start-Sleep -Seconds 2
& $adb -s $device exec-out screencap -p > "D:\pythonProject\outsource\StarChat\docs\verification\artifacts\2026-09-03\bug2-lockscreen-notification.png"
Write-Output 'saved bug2-lockscreen-notification.png'

Write-Output '--- 4) 通知记录（dumpsys） ---'
& $adb -s $device shell dumpsys notification --noredact 2>$null | Select-String -Pattern 'chatflow_messages|新消息|这个小鸿' | Select-Object -First 6
