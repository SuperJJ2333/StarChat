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
            GetuiReceiver.typeCall ->
                // 来电：原生 CallStyle 全屏链路（锁屏/息屏/后台/接听拒绝）。
                com.liuhetong.mobile.call.CallForegroundService.start(context, video = false)

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
