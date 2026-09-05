package com.liuhetong.mobile.call

import android.app.KeyguardManager
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.WindowManager
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView

/**
 * 规格§二3：Native 全屏来电页（系统电话架构；不依赖 Flutter Activity）。
 *
 * - 后台启动（Telecom/CallManager 触发，FLAG_ACTIVITY_NEW_TASK）；
 * - 锁屏/息屏：setShowWhenLocked + setTurnScreenOn + 请求解除键盘锁；
 * - 监听 CallManager 呈现状态实时刷新：ringing=接听/拒绝；
 *   answering=正在接通（仅挂断）；active=回到通话；结束事件自动关闭
 *   （远端取消/超时/挂断不再留下悬挂页面）；
 * - [接听] 是唯一的接听入口（经 CallManager→Flutter 实际执行）；
 *   全屏/正文展示意图打开本页不等于接听（规格§六2）。
 */
class CallActivity : android.app.Activity() {

    private val uiListener: (String) -> Unit = { event ->
        runOnUiThread {
            if (CallManager.state == CallManager.State.idle ||
                CallManager.state == CallManager.State.ended
            ) {
                finish()
            } else {
                render()
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 锁屏之上显示 + 点亮屏幕（Android 8+ API）。
        setShowWhenLocked(true)
        setTurnScreenOn(true)
        if (Build.VERSION.SDK_INT >= 27) {
            (getSystemService(KEYGUARD_SERVICE) as KeyguardManager).requestDismissKeyguard(
                this, null,
            )
        }
        window.addFlags(
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD or
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED,
        )
        CallManager.addUiListener(uiListener)
        render()
    }

    override fun onDestroy() {
        CallManager.removeUiListener(uiListener)
        super.onDestroy()
    }

    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        render()
    }

    private fun render() {
        val state = CallManager.state
        val ringing = state == CallManager.State.ringing
        val answering = state == CallManager.State.answering
        val name = CallManager.callerName ?: "畅聊来电"
        val title = TextView(this).apply {
            text = when {
                ringing -> name
                answering -> "正在接通 · $name"
                else -> "通话中 · $name"
            }
            textSize = 28f
            setTextColor(android.graphics.Color.WHITE)
            gravity = Gravity.CENTER
        }
        val subtitle = TextView(this).apply {
            text = if (CallManager.video) "畅聊视频来电" else "畅聊语音通话"
            textSize = 16f
            setTextColor(0xB3FFFFFF.toInt())
            gravity = Gravity.CENTER
        }
        val answer = if (ringing) {
            button("接听") {
                // 用户明确接听：answering 呈现 + Flutter 执行实际接听。
                CallManager.onAnswerRequested()
                CallManager.launchMainActivity(applicationContext)
                finish()
            }
        } else if (answering) {
            // 正在接通：接听已请求，等待 Matrix/ICE 确认（不提供重复接听）。
            button("接听中…") { /* no-op */ }
        } else {
            button("回到通话") {
                // 回到应用内通话页（仅展示，不触发接听/重复接听）。
                CallManager.launchMainActivity(applicationContext)
                finish()
            }
        }
        val reject = button(if (ringing || answering) "拒绝" else "挂断") {
            if (ringing) {
                CallManager.onRejectRequested()
            } else {
                CallManager.onEnded()
                // 通话中挂断：通知 Flutter 结束实际通话。
                NativeCallBridge.notifyUserAction(
                    applicationContext, NativeCallBridge.eventEnded,
                    CallManager.callId,
                )
            }
            finish()
        }
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            val lp = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            addView(answer, lp)
            addView(reject, lp)
        }
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setBackgroundColor(0xFF1B1B1B.toInt())
            val pad = (resources.displayMetrics.density * 32).toInt()
            setPadding(pad, pad, pad, pad)
            addView(title)
            addView(subtitle)
            addView(FrameLayout(this@CallActivity).apply { layoutParams = LinearLayout.LayoutParams(1, (resources.displayMetrics.density * 48).toInt()) })
            addView(row, LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
            // Android 14+ 全屏通知权限缺失：系统降级为横幅（本次来电不受
            // 影响）；提供一次性授权入口，下次来电起锁屏全屏可用。
            if (Build.VERSION.SDK_INT >= 34 &&
                !CallNotificationManager.canUseFullScreenIntent(this@CallActivity)
            ) {
                addView(TextView(this@CallActivity).apply {
                    text = "未获得锁屏全屏来电授权，本次以横幅提醒"
                    textSize = 12f
                    setTextColor(0x80FFFFFF.toInt())
                    gravity = Gravity.CENTER
                    val top = (resources.displayMetrics.density * 16).toInt()
                    setPadding(0, top, 0, 0)
                })
                addView(button("去授权锁屏全屏来电") {
                    CallNotificationManager.openFullScreenIntentSettings(applicationContext)
                }, LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                ).apply { gravity = Gravity.CENTER_HORIZONTAL })
            }
        }
        setContentView(root)
    }

    private fun button(label: String, onTap: () -> Unit): Button = Button(this).apply {
        text = label
        textSize = 18f
        setTextColor(android.graphics.Color.WHITE)
        when (label) {
            "接听" -> setBackgroundColor(0xFF07C160.toInt())
            "拒绝", "挂断" -> setBackgroundColor(0xFFFA5151.toInt())
            "接听中…" -> setBackgroundColor(0xFF3A3A3A.toInt())
            else -> setBackgroundColor(0xFF3A3A3A.toInt())
        }
        setOnClickListener { onTap() }
    }
}
