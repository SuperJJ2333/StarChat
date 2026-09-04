package com.liuhetong.mobile.call

import android.content.ComponentName
import android.content.Context
import android.net.Uri
import android.os.Bundle
import android.telecom.Connection
import android.telecom.ConnectionRequest
import android.telecom.ConnectionService
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import android.telecom.VideoProfile

/**
 * 规格§二1：Telecom ConnectionService——系统电话框架接管来电。
 *
 * 个推唤醒 → [reportIncoming]（TelecomManager.addNewIncomingCall）→
 * 系统创建 [CallConnection]（STATE_RINGING，系统级来电语义）；
 * 用户经系统 UI/我们的 CallActivity 接听/拒绝 → onAnswer/onReject。
 * 真实媒体/信令仍在 Flutter（Matrix/WebRTC）——本层只管来电生命周期。
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
        return connection
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
 * 自管来电连接：RINGING →（onAnswer）ACTIVE /（onReject）DISCONNECTED。
 * 事件全部转 [CallManager]，由它统一驱动 CallActivity / Flutter / 通知。
 */
class CallConnection(private val context: Context) : Connection() {
    override fun onAnswer(videoState: Int) {
        if (videoState != VideoProfile.STATE_AUDIO_ONLY &&
            videoState and VideoProfile.STATE_TX_ENABLED != 0
        ) {
            // 视频接听（当前信令不区分，按语音处理）。
        }
        setActive()
        CallManager.onAnswered()
        CallManager.launchCallActivity(context)
    }

    override fun onReject() {
        setDisconnected(android.telecom.DisconnectCause(android.telecom.DisconnectCause.REJECTED))
        CallManager.onEnded()
        CallForegroundService.stop(context)
        destroy()
    }

    override fun onDisconnect() {
        setDisconnected(android.telecom.DisconnectCause(android.telecom.DisconnectCause.LOCAL))
        CallManager.onEnded()
        CallForegroundService.stop(context)
        destroy()
    }

    fun end() {
        onDisconnect()
    }
}
