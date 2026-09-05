package com.liuhetong.mobile.call

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * 来电通知按钮接收器（规格§4/§5/§6）：
 * [接听] → CallManager.onAnswerRequested（answering 呈现 + 经
 *   NativeCallBridge 通知 Flutter 执行实际接听；Flutter 未就绪则暂存
 *   动作并拉起应用，绝不在此伪造"已接听"）；
 * [拒绝] → CallManager.onRejectRequested（Flutter reject + 呈现结束）。
 * 只携带动作，不携带任何业务内容。
 */
class IncomingCallReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        CallManager.appContext = context.applicationContext
        when (intent.action) {
            CallNotificationManager.actionAnswer -> {
                if (!CallManager.hasActiveCall()) {
                    // 陈旧通知（呈现已结束）：只清理，不触发任何接听。
                    CallNotificationManager.cancel(context)
                    return
                }
                CallManager.onAnswerRequested()
            }
            CallNotificationManager.actionReject -> {
                if (!CallManager.hasActiveCall()) {
                    CallNotificationManager.cancel(context)
                    return
                }
                CallManager.onRejectRequested()
            }
        }
    }
}
