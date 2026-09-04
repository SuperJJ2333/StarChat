package com.liuhetong.mobile.call

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * 来电通知按钮接收器（规格§4/§5/§6）：
 * [接听] → CallBridge.openIncomingCall（Flutter 打开 CallPage 并 accept）
 * [拒绝] → CallBridge.rejectIncomingCall（Flutter reject）+ 停服务。
 * 只携带动作，不携带任何业务内容。
 */
class IncomingCallReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            CallNotificationManager.actionAnswer -> {
                CallManager.onAnswered()
                CallBridge.notifyOpenIncomingCall(context)
            }
            CallNotificationManager.actionReject -> {
                CallManager.onEnded()
                CallBridge.notifyRejectIncomingCall(context)
                CallForegroundService.stop(context)
            }
        }
    }
}
