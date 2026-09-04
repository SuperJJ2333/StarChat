package com.liuhetong.mobile

import android.content.Context
import com.igexin.sdk.GTIntentService
import com.igexin.sdk.message.GTNotificationMessage
import com.igexin.sdk.message.GTTransmitMessage

/**
 * 个推消息回调服务（SDK 后台线程回调）。
 *
 * 隐私红线：
 * - 不打印 CID / 通知载荷 / 任务 ID（release 日志零泄露）；
 * - 点击事件只上报"类型"（由通用文案区分 message/call），没有也不需要
 *   房间/事件信息——推送设计上就不携带（服务端 getui-bridge 已丢弃）。
 */
class ChatFlowGetuiIntentService : GTIntentService() {

    override fun onReceiveClientId(context: Context, clientid: String) {
        GetuiBridgeState.updateCid(clientid)
    }

    override fun onReceiveOnlineState(context: Context, online: Boolean) {
        GetuiBridgeState.updateOnline(online)
    }

    override fun onNotificationMessageClicked(context: Context, message: GTNotificationMessage) {
        // 仅从通用文案推断类型：来电/消息——不含任何业务数据。
        val kind = if (message.content?.contains("来电") == true) "call" else "message"
        GetuiBridgeState.notifyClicked(kind)
    }

    // 透传消息：仅来电唤醒指令（{"type":"call","video":bool}，服务端
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
    }
}
