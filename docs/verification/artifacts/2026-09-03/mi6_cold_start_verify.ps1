# Mi 6 冷启动验证：好友重构 + SQLITE_CANTOPEN 修复构建（0.3.28+31）
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)

$adb = 'C:\Users\Administrator\AppData\Local\Android\sdk\platform-tools\adb.exe'
$device = 'cbd0156b'
$pkg = 'com.liuhetong.mobile'

Write-Output '--- 1) source markers ---'
$repo = 'D:\pythonProject\outsource\StarChat\apps\mobile_flutter\lib\features\matrix\profile_repository.dart'
Select-String -LiteralPath $repo -Pattern 'supportDirectory','Future<void> probe','SharedPreferencesProfileStore','getApplicationSupportDirectory' |
  ForEach-Object { '{0}: {1}' -f $_.LineNumber, $_.Line.Trim() }
$home = 'D:\pythonProject\outsource\StarChat\apps\mobile_flutter\lib\app_home.dart'
Select-String -LiteralPath $home -Pattern 'ProfileRepository\(widget\.api' |
  ForEach-Object { '{0}: {1}' -f $_.LineNumber, $_.Line.Trim() }

Write-Output ''
Write-Output '--- 2) device cold start ---'
& $adb -s $device shell input keyevent KEYCODE_WAKEUP | Out-Null
Start-Sleep -Seconds 1
& $adb -s $device logcat -c
& $adb -s $device shell am force-stop $pkg
Start-Sleep -Seconds 2
& $adb -s $device shell monkey -p $pkg -c android.intent.category.LAUNCHER 1 | Out-Null
Start-Sleep -Seconds 14

& $adb -s $device shell uiautomator dump /sdcard/window_dump.xml | Out-Null
$xml = [string]::Join([char]10, (& $adb -s $device exec-out cat /sdcard/window_dump.xml))
foreach ($t in @('消息', '通讯录', '发现', '我')) {
  if ($xml.Contains($t)) { "tab FOUND: $t" } else { "tab missing: $t" }
}
if ($xml.Contains('ProgressBar')) { 'spinner PRESENT (bug)' } else { 'spinner ABSENT (ok)' }

Write-Output ''
Write-Output '--- 3) flutter errors since cold start ---'
$err = (& $adb -s $device logcat -d -s flutter:E) | Select-Object -First 15
if ($err) { $err } else { '(none)' }
