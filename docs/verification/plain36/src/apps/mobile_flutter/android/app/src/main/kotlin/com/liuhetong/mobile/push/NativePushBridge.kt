package com.liuhetong.mobile.push

import android.content.Context
import android.os.Handler
import io.flutter.plugin.common.MethodChannel

/**
 * 原生推送 → Flutter 桥（规格：NativePushBridge 的 Android 侧）。
 *
 * 事件经 chatflow/push MethodChannel 送达 Flutter（引擎存活时）；
 * 引擎未起（进程被杀仅 SDK 拉活）时退化为拉起应用——由启动路由与
 * Matrix 同步呈现，绝不在此伪造业务状态。
 * 只传事件类型字符串，无业务内容。
 */
object NativePushBridge {
    const val channelName = "chatflow/push"
    const val eventPushMessage = "pushMessage"
    const val eventFriendRequest = "friendRequest"

    @Volatile private var channel: MethodChannel? = null

    fun setUp(messenger: io.flutter.plugin.common.BinaryMessenger) {
        channel = MethodChannel(messenger, channelName)
    }

    fun notifyFlutter(context: Context, event: String) {
        val ch = channel ?: run {
            launchApp(context)
            return
        }
        Handler(context.mainLooper).post { ch.invokeMethod(event, null) }
    }

    private fun launchApp(context: Context) {
        context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
            ?.let { context.startActivity(it) }
    }

    fun teardown() {
        channel = null
    }
}
