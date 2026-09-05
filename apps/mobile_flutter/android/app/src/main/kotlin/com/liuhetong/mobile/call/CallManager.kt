package com.liuhetong.mobile.call

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper

/**
 * 规格§二2：全局通话呈现状态（单例）。
 *
 * 事实来源划分（规格§七）：
 * - **真实通话状态以 Matrix/WebRTC（Flutter）为准**——经
 *   NativeCallBridge.reportCallState 回报，[updateFromFlutter] 只更新
 *   呈现，绝不回发事件（动作请求与状态回报单向流动，防循环）；
 * - 原生层只负责系统呈现（CallStyle 通知/Telecom/CallActivity），
 *   callId/caller/video/状态供各处读写，UI 刷新经 [uiListeners]。
 *
 * 状态机：idle → ringing（推送唤醒呈现）→ answering（用户已请求接听，
 * **绝不假定已连接**）→ active（Flutter 回报 connected）→ ended → idle。
 */
object CallManager {
    enum class State { idle, ringing, answering, active, ended }

    const val eventIncoming = "incomingCall"
    const val eventAccepted = "callAccepted"
    const val eventRejected = "callRejected"
    const val eventEnded = "callEnded"

    @Volatile var appContext: Context? = null
    @Volatile var state: State = State.idle
        private set
    @Volatile var callId: String? = null
        private set
    @Volatile var callerName: String? = null
        private set
    @Volatile var video: Boolean = false
        private set

    /** Matrix 同步已确认存在真实通话（类型以同步结果为准）。 */
    @Volatile var confirmed: Boolean = false
        private set

    private val mainHandler = Handler(Looper.getMainLooper())

    /** 桥事件监听（NativeCallBridge 注册/移除，→Flutter）。 */
    private val listeners = mutableListOf<(String) -> Unit>()

    /** 原生 UI 监听（CallActivity；只刷 UI，绝不回发 Flutter）。 */
    private val uiListeners = mutableListOf<(String) -> Unit>()

    @Volatile private var connection: CallConnection? = null
    private var resetRunnable: Runnable? = null

    fun addListener(listener: (String) -> Unit) {
        synchronized(listeners) { listeners.add(listener) }
    }

    fun removeListener(listener: (String) -> Unit) {
        synchronized(listeners) { listeners.remove(listener) }
    }

    fun addUiListener(listener: (String) -> Unit) {
        synchronized(uiListeners) { uiListeners.add(listener) }
    }

    fun removeUiListener(listener: (String) -> Unit) {
        synchronized(uiListeners) { uiListeners.remove(listener) }
    }

    /** 桥事件 → Flutter（经 NativeCallBridge 监听者）。 */
    fun emit(event: String) {
        val snapshot = synchronized(listeners) { listeners.toList() }
        if (snapshot.isEmpty()) return
        mainHandler.post { snapshot.forEach { it(event) } }
    }

    private fun notifyUi(event: String) {
        val snapshot = synchronized(uiListeners) { uiListeners.toList() }
        if (snapshot.isEmpty()) return
        mainHandler.post { snapshot.forEach { it(event) } }
    }

    fun hasActiveCall(): Boolean =
        state == State.ringing || state == State.answering || state == State.active

    fun attachConnection(connection: CallConnection) {
        this.connection = connection
    }

    /**
     * 个推唤醒到达：进入 ringing 呈现（仅唤醒提示，非真实通话事实）。
     * 重复唤醒幂等——正在呈现（ringing/answering/active）时直接忽略，
     * 不再以"每次推送时间戳 = 一通新电话"制造重复来电与重复页面。
     */
    fun onIncoming(callId: String, callerName: String, video: Boolean) {
        if (hasActiveCall()) return
        resetRunnable?.let { mainHandler.removeCallbacks(it) }
        resetRunnable = null
        this.callId = callId
        this.callerName = callerName
        this.video = video
        this.confirmed = false
        state = State.ringing
        emit(eventIncoming)
        notifyUi(eventIncoming)
    }

    /**
     * 用户明确请求接听：转 answering（未连接）。连接成功只可能来自
     * Flutter reportCallState(connected)——用户刚点接听绝不假定已接通。
     */
    fun onAnswerRequested() {
        if (state != State.ringing) return
        state = State.answering
        notifyUi(eventAccepted)
        NativeCallBridge.notifyUserAction(appContext, eventAccepted, callId)
    }

    /** 用户明确请求拒绝（通知原生层呈现结束 + 通知 Flutter 执行拒绝）。 */
    fun onRejectRequested() {
        if (state == State.idle || state == State.ended) return
        NativeCallBridge.notifyUserAction(appContext, eventRejected, callId)
        onEnded()
    }

    /**
     * Flutter 状态回报（Matrix/WebRTC 事实）：只更新呈现，绝不发事件。
     */
    fun updateFromFlutter(phase: String?, videoFlag: Boolean?) {
        if (phase == null) return
        if (videoFlag != null && hasActiveCall()) video = videoFlag
        when (phase) {
            "ringing" -> {
                // Matrix 同步确认真实来电存在；语音/视频类型以同步为准。
                confirmed = true
            }
            "requestingPermission", "connecting" -> {
                if (state == State.ringing || state == State.answering) {
                    state = State.answering
                    notifyUi(eventAccepted)
                }
            }
            "connected" -> {
                confirmed = true
                if (state != State.active) {
                    state = State.active
                    runCatching { connection?.setActive() }
                    notifyUi("connected")
                }
            }
            "ended", "failed", "permissionDenied", "idle" -> {
                if (state != State.idle) onEnded()
            }
        }
    }

    /**
     * 通话结束：转 ended → 桥事件 → 按通话维度清理（铃声通知/前台服务/
     * 悬浮球/Telecom Connection，不触碰普通消息同步的保活服务）→
     * 延时复位 idle。幂等：重复结束不重复发事件，只补清理。
     */
    fun onEnded() {
        if (state == State.ended || state == State.idle) {
            cleanupCall()
            return
        }
        state = State.ended
        confirmed = false
        emit(eventEnded)
        notifyUi(eventEnded)
        cleanupCall()
        resetRunnable = Runnable {
            if (state == State.ended) {
                state = State.idle
                callId = null
                callerName = null
            }
        }.also { mainHandler.postDelayed(it, 2_000) }
    }

    /** Flutter 已接管通话呈现（dismiss）：收起铃声服务与通知，保留状态。 */
    fun dismissPresentation() {
        val context = appContext ?: return
        runCatching { CallNotificationManager.cancel(context) }
        runCatching { CallForegroundService.stop(context) }
    }

    private fun cleanupCall() {
        val context = appContext ?: return
        runCatching { CallNotificationManager.cancel(context) }
        runCatching { CallForegroundService.stop(context) }
        runCatching { CallOverlayService.hide(context) }
        runCatching { connection?.hangup() }
        connection = null
    }

    fun reset() {
        resetRunnable?.let { mainHandler.removeCallbacks(it) }
        resetRunnable = null
        state = State.idle
        callId = null
        callerName = null
        confirmed = false
        connection = null
    }

    /** 后台/锁屏启动全屏来电页（规格§二3）；受限时由全屏意图兜底。 */
    fun launchCallActivity(context: Context) {
        val intent = Intent(context, CallActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        try {
            context.startActivity(intent)
        } catch (_: Exception) {
            // 后台启动 Activity 受限——全屏意图通知兜底（见 CallNotificationManager）。
        }
    }

    /** 回到应用内通话页（Flutter CallPage）：拉起主 Activity。 */
    fun launchMainActivity(context: Context) {
        val intent = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?: return
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        try {
            context.startActivity(intent)
        } catch (_: Exception) {
            // 拉起失败：用户仍可点桌面图标返回。
        }
    }
}
