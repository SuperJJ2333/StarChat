from pathlib import Path

root = Path('apps/mobile_flutter/android/app/src/main')
ok = []

# 1) CallManager：接听后挂悬浮球；来电时后台拉起 CallActivity
p = root / 'kotlin/com/liuhetong/mobile/call/CallManager.kt'
raw = p.read_text(encoding='utf-8')
raw = raw.replace("""    fun onAnswered() {
        if (state != State.ringing) return
        state = State.active
        emit("callAccepted")
    }""",
"""    fun onAnswered() {
        if (state != State.ringing) return
        state = State.active
        CallOverlayService.show(appContext ?: return)
        emit("callAccepted")
    }""", 1)
raw = raw.replace("""    @Volatile var state: State = State.idle
        private set""",
"""    @Volatile var appContext: Context? = null
    @Volatile var state: State = State.idle
        private set""", 1)
p.write_text(raw, encoding='utf-8', newline='')
ok.append('1 callmanager')

# 2) PushEventDispatcher：call → Telecom + 状态 + 原生全屏页 + 铃声 FGS
p = root / 'kotlin/com/liuhetong/mobile/push/GetuiReceiver.kt'
raw = p.read_text(encoding='utf-8')
old = """            GetuiReceiver.typeCall ->
                // 来电：原生 CallStyle 全屏链路（锁屏/息屏/后台/接听拒绝）。
                com.liuhetong.mobile.call.CallForegroundService.start(context, video = false)"""
new = """            GetuiReceiver.typeCall -> {
                // 规格§六：个推只负责唤醒；来电 UI/接听/拒绝归 Telecom。
                val cm = com.liuhetong.mobile.call.CallManager
                cm.appContext = context.applicationContext
                val callId = "call-" + System.currentTimeMillis()
                cm.onIncoming(callId, caller = "畅聊来电", video = false)
                // 系统电话框架接管（RINGING 连接 + 系统级接听语义）。
                runCatching {
                    com.liuhetong.mobile.call.CallConnectionService.reportIncoming(
                        context, callId, "畅聊来电")
                }
                // 铃声前台服务（CallStyle 通知 + 全屏意图兜底）。
                com.liuhetong.mobile.call.CallForegroundService.start(context, video = false)
                // 后台/锁屏直接尝试原生全屏来电页（受限时由全屏意图兜底）。
                cm.launchCallActivity(context)
            }"""
assert old in raw
raw = raw.replace(old, new, 1)
# caller 参数名修正：onIncoming(callId, callerName, video)
raw = raw.replace('cm.onIncoming(callId, caller = "畅聊来电", video = false)',
                  'cm.onIncoming(callId, "畅聊来电", false)', 1)
p.write_text(raw, encoding='utf-8', newline='')
ok.append('2 dispatcher')

# 3) IncomingCallReceiver：接听/拒绝同步 CallManager + 悬浮球
p = root / 'kotlin/com/liuhetong/mobile/call/IncomingCallReceiver.kt'
raw = p.read_text(encoding='utf-8')
old = """            CallNotificationManager.actionAnswer ->
                CallBridge.notifyOpenIncomingCall(context)
            CallNotificationManager.actionReject -> {
                CallBridge.notifyRejectIncomingCall(context)
                CallForegroundService.stop(context)
            }"""
new = """            CallNotificationManager.actionAnswer -> {
                CallManager.onAnswered()
                CallBridge.notifyOpenIncomingCall(context)
            }
            CallNotificationManager.actionReject -> {
                CallManager.onEnded()
                CallBridge.notifyRejectIncomingCall(context)
                CallForegroundService.stop(context)
            }"""
assert old in raw
raw = raw.replace(old, new, 1)
p.write_text(raw, encoding='utf-8', newline='')
ok.append('3 receiver')

# 4) CallNotificationManager：PhoneAccount → CallConnectionService
p = root / 'kotlin/com/liuhetong/mobile/call/CallNotificationManager.kt'
raw = p.read_text(encoding='utf-8')
raw = raw.replace(
    "android.content.ComponentName(context, ChatFlowConnectionService::class.java),",
    "android.content.ComponentName(context, CallConnectionService::class.java),", 1)
p.write_text(raw, encoding='utf-8', newline='')
ok.append('4 account')

# 5) 删除旧空壳 ConnectionService
old_cs = root / 'kotlin/com/liuhetong/mobile/call/ChatFlowConnectionService.kt'
if old_cs.exists():
    old_cs.unlink()
    ok.append('5 deleted-old-cs')

print('; '.join(ok))
