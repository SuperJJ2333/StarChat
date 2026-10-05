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
    private var avatar: android.widget.ImageView? = null
    private var fallback: android.widget.TextView? = null
    private var status: android.widget.TextView? = null
    private val handler = android.os.Handler(android.os.Looper.getMainLooper())
    private var displayedAvatar: ByteArray? = null
    private val tick = object : Runnable {
        override fun run() {
            if (!CallManager.hasActiveCall()) { stopSelf(); return }
            updatePresentation()
            handler.postDelayed(this, 1_000)
        }
    }

    private fun updatePresentation() {
        val bytes = CallManager.avatarBytes
        if (bytes !== displayedAvatar) {
            displayedAvatar = bytes
            val bitmap = bytes?.let { runCatching {
                val bounds = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
                android.graphics.BitmapFactory.decodeByteArray(it, 0, it.size, bounds)
                if (bounds.outWidth !in 1..256 || bounds.outHeight !in 1..256) null
                else android.graphics.BitmapFactory.decodeByteArray(it, 0, it.size)
            }.getOrNull() }
            avatar?.setImageBitmap(bitmap)
            avatar?.visibility = if (bitmap != null) View.VISIBLE else View.GONE
            fallback?.visibility = if (bitmap == null) View.VISIBLE else View.GONE
        }
        fallback?.text = (CallManager.callerName ?: CallManager.fallbackSeed ?: "通话").take(1)
        val origin = CallManager.connectedAtMs
        val duration = if (origin == null || CallManager.state != CallManager.State.active) "等待接通"
            else {
                val seconds = ((System.currentTimeMillis() - origin) / 1000).coerceIn(0, 86400)
                if (seconds >= 3600) String.format(java.util.Locale.ROOT, "%d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60)
                else String.format(java.util.Locale.ROOT, "%02d:%02d", seconds / 60, seconds % 60)
            }
        status?.text = duration
        val icon = if (CallManager.video) android.R.drawable.presence_video_online
            else android.R.drawable.sym_action_call
        status?.setCompoundDrawablesWithIntrinsicBounds(icon, 0, 0, 0)
        ball?.contentDescription = "返回通话 ${CallManager.callerName ?: ""} $duration"
    }

    override fun onBind(intent: android.content.Intent?) = null

    override fun onStartCommand(intent: android.content.Intent?, flags: Int, startId: Int): Int {
        val wm = getSystemService(WINDOW_SERVICE) as WindowManager
        if (!CallManager.hasActiveCall() || !Settings.canDrawOverlays(this)) {
            stopSelf()
            return START_NOT_STICKY
        }
        if (ball != null) return START_NOT_STICKY
        val density = resources.displayMetrics.density
        val size = (density * 88).toInt()
        ball = android.widget.LinearLayout(this).apply {
            orientation = android.widget.LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            val padding = (density * 8).toInt()
            setPadding(padding, padding, padding, padding)
            background = android.graphics.drawable.GradientDrawable().apply {
                setColor(0xFFF7F7F7.toInt()); cornerRadius = density * 12
            }
            val avatarSize = (density * 48).toInt()
            val frame = android.widget.FrameLayout(this@CallOverlayService)
            avatar = android.widget.ImageView(this@CallOverlayService).apply {
                scaleType = android.widget.ImageView.ScaleType.CENTER_CROP
                visibility = View.GONE
            }
            fallback = android.widget.TextView(this@CallOverlayService).apply {
                gravity = Gravity.CENTER; textSize = 20f; setTextColor(0xFF191919.toInt())
                setBackgroundColor(0xFFDFF2E4.toInt())
            }
            frame.addView(fallback, android.widget.FrameLayout.LayoutParams(avatarSize, avatarSize))
            frame.addView(avatar, android.widget.FrameLayout.LayoutParams(avatarSize, avatarSize))
            addView(frame, android.widget.LinearLayout.LayoutParams(avatarSize, avatarSize))
            status = android.widget.TextView(this@CallOverlayService).apply {
                gravity = Gravity.CENTER; textSize = 12f; setTextColor(0xFF07C160.toInt())
                compoundDrawablePadding = (density * 4).toInt()
            }
            addView(status, android.widget.LinearLayout.LayoutParams(-2, -2))
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
                                CallManager.returnToCall(applicationContext)
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
            return START_NOT_STICKY
        }
        // 通话结束自动移除（引用持有，onDestroy 时注销防泄漏）。
        val listener: (String) -> Unit = { event ->
            if (event == CallManager.eventEnded) stopSelf() else updatePresentation()
        }
        overlayListener = listener
        CallManager.addUiListener(listener)
        handler.post(tick)
        return START_NOT_STICKY
    }

    private var overlayListener: ((String) -> Unit)? = null

    private fun layoutParamsOf(x: Int, y: Int, size: Int = (resources.displayMetrics.density * 88).toInt()) =
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
        overlayListener?.let { CallManager.removeUiListener(it) }
        overlayListener = null
        val wm = getSystemService(WINDOW_SERVICE) as WindowManager
        ball?.let { runCatching { wm.removeView(it) } }
        ball = null
        handler.removeCallbacks(tick)
        displayedAvatar = null
        avatar = null
        fallback = null
        status = null
        super.onDestroy()
    }

    companion object {
        fun show(context: Context): Boolean {
            // 通话期间进程持有 ongoing-call 前台服务：普通 startService 即可
            //（无需再挂一个前台通知；失败=无悬浮球，通话不受影响）。
            if (!CallManager.hasActiveCall() || !Settings.canDrawOverlays(context)) return false
            return runCatching {
                context.startService(
                    android.content.Intent(context, CallOverlayService::class.java))
                true
            }.getOrDefault(false)
        }

        fun hide(context: Context) {
            context.stopService(android.content.Intent(context, CallOverlayService::class.java))
        }
    }
}
