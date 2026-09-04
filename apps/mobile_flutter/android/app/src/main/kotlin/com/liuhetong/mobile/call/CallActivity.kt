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
 * - ringing：接听/拒绝；active：显示"回到通话"（点击拉起应用内 CallPage）。
 */
class CallActivity : android.app.Activity() {

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
        render()
    }

    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        render()
    }

    private fun render() {
        val ringing = CallManager.state == CallManager.State.ringing
        val name = CallManager.callerName ?: "畅聊来电"
        val title = TextView(this).apply {
            text = if (ringing) name else "通话中 · $name"
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
        val answer = button(if (ringing) "接听" else "回到通话") {
            if (ringing) {
                CallManager.onAnswered()
                // 打开应用（Flutter 接管接听：app_home 监听 callAccepted）。
                CallBridge.notifyOpenIncomingCall(applicationContext)
            } else {
                CallBridge.notifyOpenIncomingCall(applicationContext)
            }
            finish()
        }
        val reject = button(if (ringing) "拒绝" else "挂断") {
            if (ringing) {
                CallBridge.notifyRejectIncomingCall(applicationContext)
            } else {
                CallBridge.notifyCallEnded(applicationContext)
            }
            CallManager.onEnded()
            CallForegroundService.stop(applicationContext)
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
            else -> setBackgroundColor(0xFF3A3A3A.toInt())
        }
        setOnClickListener { onTap() }
    }
}
