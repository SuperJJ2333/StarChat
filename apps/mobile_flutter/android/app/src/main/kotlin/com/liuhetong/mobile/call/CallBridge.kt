package com.liuhetong.mobile.call

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Flutter ↔ Native 通话桥（chatflow/call，规格§4/§5/§6）：
 * 仅承载 Flutter→原生 dismiss（Flutter 已接管通话，收起原生前台服务
 * 与来电通知）。接听/拒绝动作统一走 [NativeCallBridge]（native_call）
 * 单一通道，避免双通道重复触发接听。
 * 只传动作类型，不携带任何业务内容（隐私红线）。
 */
object CallBridge {
    const val channelName = "chatflow/call"
    const val methodDismiss = "dismiss"

    @Volatile private var channel: MethodChannel? = null

    fun setUp(messenger: BinaryMessenger, onDismiss: () -> Unit) {
        val ch = MethodChannel(messenger, channelName)
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                methodDismiss -> {
                    onDismiss()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        channel = ch
    }

    fun teardown() {
        channel?.setMethodCallHandler(null)
        channel = null
    }
}

/**
 * 规格§三：native_call 通道。
 *
 * Native→Flutter 事件：incomingCall（推送唤醒呈现，仅登记）/
 * callAccepted（用户明确请求接听）/ callRejected（用户明确请求拒绝）/
 * callEnded（呈现结束：超时/远端取消/清理）。
 *
 * Flutter→Native 方法：ready（就绪握手，取回冷启动暂存动作与当前呈现）/
 * reportCallState（Matrix/WebRTC 状态回报，只更新呈现不回发）/
 * answerCall / rejectCall / endCall（应用内用户动作）/ getActiveCall。
 *
 * 就绪握手：通道对象存在 ≠ 业务处理器就绪。[methodReady] 之前到达的
 * 用户动作经 [notifyUserAction] 暂存（PendingCallActions）并拉起应用，
 * 不伪造接听、不丢失动作。
 */
object NativeCallBridge {
    const val channelName = "native_call"
    const val methodReady = "ready"
    const val methodReportState = "reportCallState"
    const val methodGetActive = "getActiveCall"
    const val methodAnswer = "answerCall"
    const val methodReject = "rejectCall"
    const val methodEnd = "endCall"

    const val eventIncoming = "incomingCall"
    const val eventAccepted = "callAccepted"
    const val eventRejected = "callRejected"
    const val eventEnded = "callEnded"

    class CallHandlers(
        val onAnswer: () -> Unit,
        val onReject: () -> Unit,
        val onEnd: () -> Unit,
    )

    @Volatile private var channel: MethodChannel? = null
    @Volatile private var callListener: ((String) -> Unit)? = null
    @Volatile private var handlers: CallHandlers? = null

    /** Flutter 业务处理器就绪（AppHome 完成握手）。 */
    @Volatile private var flutterReady = false

    /**
     * 创建通道 + 注册方法处理器 + 订阅 CallManager 事件。
     * 幂等：重复调用先 teardown（Activity 重建/引擎重建不泄漏监听）。
     */
    fun setUp(messenger: BinaryMessenger, callHandlers: CallHandlers) {
        teardown()
        handlers = callHandlers
        val ch = MethodChannel(messenger, channelName)
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                methodReady -> {
                    flutterReady = true
                    result.success(
                        mapOf(
                            "actions" to PendingCallActions.drain().map {
                                mapOf(
                                    "callId" to it.callId,
                                    "action" to it.action,
                                    "at" to it.atMs,
                                )
                            },
                            "activeCall" to activeCallSnapshot(),
                        )
                    )
                }
                methodReportState -> {
                    CallManager.updateFromFlutter(
                        call.argument<String>("phase"),
                        call.argument<Boolean>("video"),
                    )
                    result.success(true)
                }
                methodGetActive -> result.success(activeCallSnapshot())
                methodAnswer -> {
                    handlers?.onAnswer()
                    result.success(true)
                }
                methodReject -> {
                    handlers?.onReject()
                    result.success(true)
                }
                methodEnd -> {
                    handlers?.onEnd()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        channel = ch
        val listener: (String) -> Unit = { event -> emitToFlutter(event) }
        callListener = listener
        CallManager.addListener(listener)
    }

    private fun activeCallSnapshot(): Map<String, Any?> = mapOf(
        "state" to CallManager.state.name,
        "callId" to CallManager.callId,
        "callerName" to CallManager.callerName,
        "video" to CallManager.video,
        "confirmed" to CallManager.confirmed,
    )

    /**
     * 原生用户动作 → Flutter。引擎未起或未完成 ready 握手时暂存动作
     * 并拉起应用（冷启动经 ready 取回重放）；就绪则直发事件。
     */
    fun notifyUserAction(context: Context?, event: String, callId: String?) {
        if (!flutterReady) {
            when (event) {
                eventAccepted -> PendingCallActions.store(
                    callId, PendingCallActions.ACTION_ANSWER)
                eventRejected -> PendingCallActions.store(
                    callId, PendingCallActions.ACTION_REJECT)
            }
            context?.let { launchApp(it) }
            return
        }
        emitToFlutter(event, callId ?: CallManager.callId)
    }

    private fun emitToFlutter(method: String) {
        emitToFlutter(method, CallManager.callId)
    }

    private fun emitToFlutter(method: String, callId: String?) {
        val ch = channel ?: return
        if (!flutterReady) return
        Handler(Looper.getMainLooper()).post {
            ch.invokeMethod(method, mapOf("callId" to callId))
        }
    }

    private fun launchApp(context: Context) {
        val intent = context.packageManager.getLaunchIntentForPackage(context.packageName)
        intent?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        intent?.let { runCatching { context.startActivity(it) } }
    }

    fun teardown() {
        callListener?.let { CallManager.removeListener(it) }
        callListener = null
        channel?.setMethodCallHandler(null)
        channel = null
        handlers = null
        flutterReady = false
    }
}
