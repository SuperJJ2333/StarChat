from pathlib import Path

root = Path('apps/mobile_flutter/android/app/src/main')

# 6) MainActivity：NativeCallBridge 控制处理器
p = root / 'kotlin/com/liuhetong/mobile/MainActivity.kt'
raw = p.read_text(encoding='utf-8')
anchor = """        com.liuhetong.mobile.call.CallBridge.setUp("""
inject = """        com.liuhetong.mobile.call.NativeCallBridge.setCallHandler(
            onAnswer = {
                com.liuhetong.mobile.call.CallManager.onAnswered()
                com.liuhetong.mobile.call.CallManager
                    .launchCallActivity(applicationContext)
            },
            onReject = {
                com.liuhetong.mobile.call.CallManager.onEnded()
                com.liuhetong.mobile.call.CallForegroundService.stop(applicationContext)
            },
            onEnd = {
                com.liuhetong.mobile.call.CallManager.onEnded()
                com.liuhetong.mobile.call.CallForegroundService.stop(applicationContext)
                com.liuhetong.mobile.call.CallOverlayService.hide(applicationContext)
            },
        )
        com.liuhetong.mobile.call.CallBridge.setUp("""
if 'NativeCallBridge.setCallHandler' not in raw:
    assert anchor in raw
    raw = raw.replace(anchor, inject, 1)
    p.write_text(raw, encoding='utf-8', newline='')
print('6 MainActivity OK')

# 7) Manifest：权限 + CallActivity + CallConnectionService + Overlay
p = root / 'AndroidManifest.xml'
raw = p.read_text(encoding='utf-8')
perm_anchor = '<uses-permission android:name="android.permission.FOREGROUND_SERVICE_PHONE_CALL" />'
extra_perms = perm_anchor + """
    <uses-permission android:name="android.permission.USE_FULL_SCREEN_INTENT" />
    <uses-permission android:name="android.permission.SYSTEM_ALERT_WINDOW" />
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />"""
assert perm_anchor in raw
raw = raw.replace(perm_anchor, extra_perms, 1)
# 组件：CallActivity / Overlay / ConnectionService 改指新类
old_svc = '<service\n            android:name=".call.ChatFlowConnectionService"'
assert old_svc in raw
raw = raw.replace(
    'android:name=".call.ChatFlowConnectionService"',
    'android:name=".call.CallConnectionService"', 1)
components_anchor = '<receiver\n            android:name=".call.IncomingCallReceiver"\n            android:exported="false" />'
new_components = components_anchor + """

        <activity
            android:name=".call.CallActivity"
            android:excludeFromRecents="true"
            android:exported="false"
            android:launchMode="singleTop"
            android:showWhenLocked="true"
            android:turnScreenOn="true"
            android:theme="@style/Theme.AppCompat.NoActionBar" />
        <service
            android:name=".call.CallOverlayService"
            android:exported="false" />"""
assert components_anchor in raw
raw = raw.replace(components_anchor, new_components, 1)
p.write_text(raw, encoding='utf-8', newline='')
print('7 Manifest OK')
