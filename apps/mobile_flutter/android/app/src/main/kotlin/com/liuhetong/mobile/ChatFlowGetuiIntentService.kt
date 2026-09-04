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

    // 透传消息（我们不用透传通道；即便收到也不处理任何内容）。
    override fun onReceiveMessageData(context: Context, msg: GTTransmitMessage) {
        // 有意忽略。
    }
}
