# 轮次验证：前台服务（BUG2）+ canonical 注册（BUG1）
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$adb = 'C:\Users\Administrator\AppData\Local\Android\sdk\platform-tools\adb.exe'
$device = 'cbd0156b'

& $adb -s $device shell input keyevent KEYCODE_WAKEUP | Out-Null
Start-Sleep -Seconds 1
& $adb -s $device shell am force-stop com.liuhetong.mobile
Start-Sleep -Seconds 2
& $adb -s $device shell monkey -p com.liuhetong.mobile -c android.intent.category.LAUNCHER 1 | Out-Null
Write-Output 'app launched, waiting 15s for FGS + notification system...'
Start-Sleep -Seconds 15

Write-Output '--- foreground service state ---'
& $adb -s $device shell dumpsys activity services com.liuhetong.mobile | Select-String -Pattern 'ServiceRecord|foregroundServiceType|app=' | Select-Object -First 6

Write-Output '--- sync notification posted? ---'
& $adb -s $device shell dumpsys notification --noredact 2>$null | Select-String -Pattern 'chatflow_sync|消息同步|消息服务运行中' | Select-Object -First 4

Write-Output '--- process foreground importance ---'
& $adb -s $device shell dumpsys activity processes 2>$null | Select-String -Pattern 'com.liuhetong.mobile' | Select-Object -First 2
