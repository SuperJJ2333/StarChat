package com.liuhetong.mobile.call

import android.content.ComponentName
import android.content.Context
import android.net.Uri
import android.os.Bundle
import android.telecom.Connection
import android.telecom.ConnectionRequest
import android.telecom.ConnectionService
import android.telecom.DisconnectCause
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager

/**
 * 规格§二1：Telecom 自管理 ConnectionService——系统电话框架接管来电呈现。
 *
 * 个推唤醒 → [reportIncoming]（TelecomManager.addNewIncomingCall）→
 * 系统创建 [CallConnection]（STATE_RINGING，系统级来电语义）。
 * 真实媒体/信令在 Flutter（Matrix/WebRTC）——本层只管系统呈现：
 * - onAnswer：Telecom 层确认接听，连接转 ACTIVE；**应用层连接成功
 *   仍以 Flutter reportCallState(connected) 为准**（CallManager 保持
 *   answering 直到回报到达）；
 * - onReject / onDisconnect：呈现结束 + 按通话维度清理；
 * - onCreateIncomingConnectionFailed：系统拒绝接入时清理，不留残留。
 */
class CallConnectionService : ConnectionService() {

    override fun onCreateIncomingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest,
    ): Connection {
        val connection = CallConnection(this)
        connection.connectionProperties =
            Connection.PROPERTY_SELF_MANAGED
        connection.setRinging()
        CallManager.appContext = applicationContext
        CallManager.attachConnection(connection)
        return connection
    }

    /** 系统拒绝创建来电连接（权限/账号问题）：清理呈现，不吞异常痕迹。 */
    override fun onCreateIncomingConnectionFailed(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest,
    ) {
        super.onCreateIncomingConnectionFailed(connectionManagerPhoneAccount, request)
        CallManager.onEnded()
    }

    companion object {
        fun handle(context: Context): PhoneAccountHandle =
            PhoneAccountHandle(
                ComponentName(context, CallConnectionService::class.java),
                "chatflow_calls",
            )

        /** 上报系统：新来电（自管账号，不弹系统默认拨号 UI 拦截）。 */
        fun reportIncoming(context: Context, callId: String, caller: String) {
            val telecom =
                context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
            val handle = handle(context)
            if (telecom.getPhoneAccount(handle) == null) {
                val account = android.telecom.PhoneAccount.Builder(handle, "畅聊")
                    .setCapabilities(android.telecom.PhoneAccount.CAPABILITY_SELF_MANAGED)
                    .build()
                telecom.registerPhoneAccount(account)
            }
            val extras = Bundle().apply {
                putParcelable(TelecomManager.EXTRA_INCOMING_CALL_ADDRESS, Uri.parse("tel:$callId"))
                putBoolean(TelecomManager.EXTRA_START_CALL_WITH_VIDEO_STATE, false)
            }
            telecom.addNewIncomingCall(handle, extras)
        }
    }
}

/**
 * 自管来电连接：RINGING →（onAnswer）ACTIVE /（onReject|onDisconnect）
 * DISCONNECTED。事件全部转 [CallManager] 统一驱动 CallActivity / Flutter /
 * 通知；媒体连接事实以 Flutter 状态回报为准。
 */
class CallConnection(private val context: Context) : Connection() {

    private var finished = false

    override fun onAnswer(videoState: Int) {
        // Telecom 层确认接听请求；视频类型以 Matrix 同步结果为准
        // （CallManager.video 由 reportCallState 更新）。
        setActive()
        CallManager.onAnswerRequested()
        CallManager.launchCallActivity(context)
    }

    override fun onReject() {
        finish(DisconnectCause(DisconnectCause.REJECTED))
    }

    override fun onDisconnect() {
        finish(DisconnectCause(DisconnectCause.LOCAL))
    }

    /** 由 CallManager 清理时调用（finished 防递归）。 */
    fun hangup() {
        finish(DisconnectCause(DisconnectCause.LOCAL))
    }

    private fun finish(cause: DisconnectCause) {
        if (finished) return
        finished = true
        setDisconnected(cause)
        CallManager.onEnded()
        destroy()
    }
}
