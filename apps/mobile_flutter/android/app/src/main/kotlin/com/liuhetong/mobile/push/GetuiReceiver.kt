package com.liuhetong.mobile.push

import android.content.Context
import org.json.JSONObject

/**
 * 个推事件接收与业务分发入口（规格：GetuiReceiver + PushEventDispatcher）。
 *
 * 个推 SDK 的回调入口是 ChatFlowGetuiIntentService（GTIntentService 子类，
 * SDK 线程回调，非 manifest 广播）——本类承接其透传载荷并按 type 分发：
 * - message       → Flutter chatflow/push → NotificationCoordinator 系统通知
 * - friend_request→ Flutter chatflow/push → 角标 + 好友红点
 * - call          → CallForegroundService（CallStyle 全屏来电，绝不用普通通知）
 * 载荷只含 type 类别；不打印任何内容（隐私红线）。
 */
object GetuiReceiver {

    const val typeMessage = "message"
    const val typeFriendRequest = "friend_request"
    const val typeCall = "call"

    fun onTransmit(context: Context, payloadJson: String) {
        val type = try {
            JSONObject(payloadJson).optString("type")
        } catch (_: Exception) {
            return
        }
        PushEventDispatcher.dispatch(context, type)
    }
}

/**
 * 按推送事件类型分发到对应域（纯路由，不解析业务内容）。
 */
object PushEventDispatcher {

    fun dispatch(context: Context, type: String) {
        when (type) {
            GetuiReceiver.typeCall -> {
                // 规格§六：个推只负责唤醒；来电 UI/接听/拒绝归 Telecom。
                val cm = com.liuhetong.mobile.call.CallManager
                cm.appContext = context.applicationContext
                val callId = "call-" + System.currentTimeMillis()
                cm.onIncoming(callId, "畅聊来电", false)
                // 系统电话框架接管（RINGING 连接 + 系统级接听语义）。
                runCatching {
                    com.liuhetong.mobile.call.CallConnectionService.reportIncoming(
                        context, callId, "畅聊来电")
                }
                // 铃声前台服务（CallStyle 通知 + 全屏意图兜底）。
                com.liuhetong.mobile.call.CallForegroundService.start(context, video = false)
                // 后台/锁屏直接尝试原生全屏来电页（受限时由全屏意图兜底）。
                cm.launchCallActivity(context)
            }

            GetuiReceiver.typeMessage ->
                // 消息：交 Flutter（NotificationCoordinator 落系统通知）。
                NativePushBridge.notifyFlutter(
                    context, NativePushBridge.eventPushMessage,
                )

            GetuiReceiver.typeFriendRequest ->
                // 好友申请：角标 + 通讯录红点（Flutter BadgeService）。
                NativePushBridge.notifyFlutter(
                    context, NativePushBridge.eventFriendRequest,
                )
        }
    }
}
