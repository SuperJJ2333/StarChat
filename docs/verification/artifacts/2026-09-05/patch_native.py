from pathlib import Path

root = Path('apps/mobile_flutter')

# 1) Getui 透传入口：type=call → 启动 CallForegroundService
p = root / 'android/app/src/main/kotlin/com/liuhetong/mobile/ChatFlowGetuiIntentService.kt'
raw = p.read_text(encoding='utf-8')
old = """    // 透传消息（我们不用透传通道；即便收到也不处理任何内容）。
    override fun onReceiveMessageData(context: Context, msg: GTTransmitMessage) {
        // 有意忽略。
    }"""
new = """    // 透传消息：仅来电唤醒指令（{"type":"call","video":bool}，服务端
    // getui-bridge 不携带任何业务内容）。其余透传一律忽略。
    override fun onReceiveMessageData(context: Context, msg: GTTransmitMessage) {
        try {
            val payload = msg.payload?.toString(Charsets.UTF_8) ?: return
            val obj = org.json.JSONObject(payload)
            if (obj.optString("type") != "call") return
            val video = obj.optBoolean("video", false)
            com.liuhetong.mobile.call.CallForegroundService.start(context, video)
        } catch (_: Exception) {
            // 非法载荷忽略（不打印内容）。
        }
    }"""
assert old in raw
p.write_text(raw.replace(old, new), encoding='utf-8', newline='')
print('1 intent-service OK')

# 2) AndroidManifest：权限 + 组件注册
p = root / 'android/app/src/main/AndroidManifest.xml'
raw = p.read_text(encoding='utf-8')
perm_anchor = 'android:foregroundServiceType="dataSync|microphone|camera" />'
components = """android:foregroundServiceType="dataSync|microphone|camera" />

        <!-- 原生通话层（微信级后台来电）：phoneCall 前台服务 + CallStyle -->
        <uses-permission android:name="android.permission.MANAGE_OWN_CALLS" />
        <uses-permission android:name="android.permission.FOREGROUND_SERVICE_PHONE_CALL" />

        <service
            android:name=".call.CallForegroundService"
            android:exported="false"
            android:foregroundServiceType="phoneCall" />
        <service
            android:name=".call.ChatFlowConnectionService"
            android:permission="android.permission.BIND_TELECOM_CONNECTION_SERVICE"
            android:exported="false">
            <intent-filter>
                <action android:name="android.telecom.ConnectionService" />
            </intent-filter>
        </service>
        <receiver
            android:name=".call.IncomingCallReceiver"
            android:exported="false" />"""
assert perm_anchor in raw
raw = raw.replace(perm_anchor, components, 1)
p.write_text(raw, encoding='utf-8', newline='')
print('2 manifest OK')

# 3) MainActivity：CallBridge 装配
p = root / 'android/app/src/main/kotlin/com/liuhetong/mobile/MainActivity.kt'
raw = p.read_text(encoding='utf-8')
anchor = 'configureFlutterEngine'
if 'CallBridge.setUp' not in raw:
    # 在 onListen 注册之后插入（找 EventChannel setMethodCallHandler/engine 之后）：
    marker = 'override fun configureFlutterEngine(engine: FlutterEngine) {'
    assert marker in raw
    inject = marker + """
        com.liuhetong.mobile.call.CallBridge.setUp(
            engine.dartExecutor.binaryMessenger,
        ) {
            // Flutter 已接管通话（接听/拒绝/结束）：停原生前台服务与通知。
            com.liuhetong.mobile.call.CallForegroundService.stop(applicationContext)
        }"""
    raw = raw.replace(marker, inject, 1)
    p.write_text(raw, encoding='utf-8', newline='')
print('3 mainactivity OK')
