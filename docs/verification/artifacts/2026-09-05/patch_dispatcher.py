from pathlib import Path

root = Path('apps/mobile_flutter')

# 1) GTIntentService：透传 → GetuiReceiver 统一分发
p = root / 'android/app/src/main/kotlin/com/liuhetong/mobile/ChatFlowGetuiIntentService.kt'
raw = p.read_text(encoding='utf-8')
old = """    override fun onReceiveMessageData(context: Context, msg: GTTransmitMessage) {
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
new = """    override fun onReceiveMessageData(context: Context, msg: GTTransmitMessage) {
        // 透传事件统一经 GetuiReceiver → PushEventDispatcher 分发
        // （message/friend_request/call），本服务不做业务判断。
        try {
            val payload = msg.payload?.toString(Charsets.UTF_8) ?: return
            com.liuhetong.mobile.push.GetuiReceiver.onTransmit(context, payload)
        } catch (_: Exception) {
            // 非法载荷忽略（不打印内容）。
        }
    }"""
assert old in raw
p.write_text(raw.replace(old, new), encoding='utf-8', newline='')
print('1 entry OK')

# 2) MainActivity：装配 NativePushBridge 通道
p = root / 'android/app/src/main/kotlin/com/liuhetong/mobile/MainActivity.kt'
raw = p.read_text(encoding='utf-8')
marker = 'com.liuhetong.mobile.call.CallBridge.setUp('
inject = """com.liuhetong.mobile.push.NativePushBridge.setUp(
            flutterEngine.dartExecutor.binaryMessenger,
        )
        com.liuhetong.mobile.call.CallBridge.setUp("""
if 'NativePushBridge.setUp' not in raw:
    assert marker in raw
    raw = raw.replace(marker, inject, 1)
    p.write_text(raw, encoding='utf-8', newline='')
print('2 mainactivity OK')
