package com.liuhetong.mobile.call

import android.content.Context
import android.graphics.PixelFormat
import android.os.Build
import android.provider.Settings
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager

/**
 * 规格§五：通话悬浮球（Overlay Window）。
 * 通话 active 期间显示小圆球（SYSTEM_ALERT_WINDOW），点击回到通话
 * （CallActivity "回到通话" → Flutter CallPage）。无 overlay 权限时
 * 安全退化为无悬浮球（通话不中断）。
 */
class CallOverlayService : android.app.Service() {

    private var ball: View? = null

    override fun onBind(intent: android.content.Intent?) = null

    override fun onStartCommand(intent: android.content.Intent?, flags: Int, startId: Int): Int {
        val wm = getSystemService(WINDOW_SERVICE) as WindowManager
        if (ball != null) return START_STICKY
        if (!Settings.canDrawOverlays(this)) return START_NOT_STICKY
        val density = resources.displayMetrics.density
        val size = (density * 52).toInt()
        ball = android.widget.ImageView(this).apply {
            setImageResource(applicationInfo.icon)
            setBackgroundColor(0xE607C160.toInt())
            alpha = 0.92f
            setOnTouchListener(object : View.OnTouchListener {
                var downX = 0f; var downY = 0f; var startX = 0f; var startY = 0f
                override fun onTouch(v: View, e: MotionEvent): Boolean {
                    when (e.action) {
                        MotionEvent.ACTION_DOWN -> {
                            downX = e.rawX; downY = e.rawY
                            startX = (v.tag as? IntArray)?.get(0)?.toFloat() ?: 0f
                            startY = (v.tag as? IntArray)?.get(1)?.toFloat() ?: 0f
                        }
                        MotionEvent.ACTION_MOVE -> {
                            val p = (v.tag as? IntArray) ?: intArrayOf(0, 0)
                            p[0] = (startX + e.rawX - downX).toInt()
                            p[1] = (startY + e.rawY - downY).toInt()
                            wm.updateViewLayout(v, layoutParamsOf(p[0], p[1]))
                        }
                        MotionEvent.ACTION_UP -> {
                            val moved = kotlin.math.abs(e.rawX - downX) + kotlin.math.abs(e.rawY - downY)
                            if (moved < 12) {
                                CallManager.launchCallActivity(applicationContext)
                                return true
                            }
                        }
                    }
                    return true
                }
            })
            tag = intArrayOf(0, 0)
        }
        try {
            wm.addView(ball, layoutParamsOf(0, 0, size))
        } catch (_: Exception) {
            stopSelf()
        }
        // 通话结束自动移除。
        CallManager.addListener { event ->
            if (event == CallManagerEventEnded) stopSelf()
        }
        return START_STICKY
    }

    private fun layoutParamsOf(x: Int, y: Int, size: Int = (resources.displayMetrics.density * 52).toInt()) =
        WindowManager.LayoutParams(
            if (Build.VERSION.SDK_INT >= 26)
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            else
                @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
            PixelFormat.TRANSLUCENT,
        ).apply {
            width = size; height = size
            gravity = Gravity.TOP or Gravity.START
            this.x = x; this.y = y
        }

    override fun onDestroy() {
        val wm = getSystemService(WINDOW_SERVICE) as WindowManager
        ball?.let { runCatching { wm.removeView(it) } }
        ball = null
        super.onDestroy()
    }

    companion object {
        fun show(context: Context) {
            // 通话期间进程持有 ongoing-call 前台服务：普通 startService 即可
            //（无需再挂一个前台通知；失败=无悬浮球，通话不受影响）。
            runCatching {
                context.startService(
                    android.content.Intent(context, CallOverlayService::class.java))
            }
        }

        fun hide(context: Context) {
            context.stopService(android.content.Intent(context, CallOverlayService::class.java))
        }
    }
}
