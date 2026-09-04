package com.liuhetong.mobile.call

import android.content.Context
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.BinaryMessenger

/**
 * Flutter ↔ Native 通话桥（规格§4/§5/§6）：
 * - Native→Flutter：来电通知点[接听]→ openIncomingCall；点[拒绝]→ rejectIncomingCall。
 * - Flutter→Native：dismiss（Flutter 已接管通话，停原生前台服务与通知）。
 * 只传动作类型，不携带任何业务内容（隐私红线）。
 */
object CallBridge {
    const val channelName = "chatflow/call"
    const val methodOpenIncomingCall = "openIncomingCall"
    const val methodRejectIncomingCall = "rejectIncomingCall"
    const val methodDismiss = "dismiss"

    @Volatile private var channel: MethodChannel? = null
    @Volatile private var handler: MethodChannel.MethodCallHandler? = null

    fun setUp(messenger: BinaryMessenger, onDismiss: () -> Unit) {
        val ch = MethodChannel(messenger, channelName)
        handler = MethodChannel.MethodCallHandler { call, result ->
            when (call.method) {
                methodDismiss -> {
                    onDismiss()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        ch.setMethodCallHandler(handler)
        channel = ch
    }

    fun notifyOpenIncomingCall(context: Context) {
        invoke(context, methodOpenIncomingCall)
    }

    fun notifyRejectIncomingCall(context: Context) {
        invoke(context, methodRejectIncomingCall)
    }

    private fun invoke(context: Context, method: String) {
        val ch = channel
        if (ch == null) {
            // Flutter 引擎未起（进程被杀后仅 SDK 拉活）：点按即拉起应用，
            // 由既有的全屏意图/启动路由接管，不在此伪造接听。
            launchApp(context)
            return
        }
        android.os.Handler(context.mainLooper).post {
            ch.invokeMethod(method, null)
        }
    }

    private fun launchApp(context: Context) {
        val intent = context.packageManager.getLaunchIntentForPackage(context.packageName)
        intent?.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
        intent?.let { context.startActivity(it) }
    }

    fun teardown() {
        channel?.setMethodCallHandler(null)
        channel = null
        handler = null
    }
}
