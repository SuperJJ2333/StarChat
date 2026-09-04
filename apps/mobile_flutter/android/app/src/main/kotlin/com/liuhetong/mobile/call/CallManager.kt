package com.liuhetong.mobile.call

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper

/**
 * 规格§二2：全局通话状态管理（单例）。
 *
 * callId/caller/video/状态（ringing/active/ended）唯一权威；
 * Telecom、CallActivity、通知、Flutter 桥都从这里读写。
 * 事件回调经 [listeners] 广播（主线程）。
 */
object CallManager {
    enum class State { idle, ringing, active, ended }

    @Volatile var appContext: Context? = null
    @Volatile var state: State = State.idle
        private set
    @Volatile var callId: String? = null
        private set
    @Volatile var callerName: String? = null
        private set
    @Volatile var video: Boolean = false
        private set

    private val listeners = mutableListOf<(String) -> Unit>() // 事件名回调

    fun addListener(listener: (String) -> Unit) {
        synchronized(listeners) { listeners.add(listener) }
    }

    fun removeListener(listener: (String) -> Unit) {
        synchronized(listeners) { listeners.remove(listener) }
    }

    fun emit(event: String) {
        val snapshot = synchronized(listeners) { listeners.toList() }
        Handler(Looper.getMainLooper()).post {
            snapshot.forEach { it(event) }
        }
    }

    fun hasActiveCall(): Boolean =
        state == State.ringing || state == State.active

    /** 个推唤醒到达：进入 ringing（重复唤醒同 callId 幂等）。 */
    fun onIncoming(callId: String, callerName: String, video: Boolean) {
        if (state == State.ringing && this.callId == callId) return
        this.callId = callId
        this.callerName = callerName
        this.video = video
        state = State.ringing
        emit("incomingCall")
    }

    fun onAnswered() {
        if (state != State.ringing) return
        state = State.active
        CallOverlayService.show(appContext ?: return)
        emit("callAccepted")
    }

    fun onEnded() {
        if (state == State.idle) return
        state = State.ended
        emit("callEnded")
        Handler(Looper.getMainLooper()).postDelayed({
            if (state == State.ended) {
                state = State.idle
                callId = null
                callerName = null
            }
        }, 2_000)
    }

    fun reset() {
        state = State.idle
        callId = null
        callerName = null
    }

    /** 后台/锁屏启动全屏来电页（规格§二3）。 */
    fun launchCallActivity(context: Context) {
        val intent = Intent(context, CallActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        try {
            context.startActivity(intent)
        } catch (_: Exception) {
            // 后台启动 Activity 受限（无悬浮窗权限等）——全屏意图通知兜底。
        }
    }
}
