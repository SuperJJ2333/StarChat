package com.liuhetong.mobile.call

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import androidx.core.content.ContextCompat

/**
 * 来电前台服务（规格§1/§2/§7）：个推 type=call 透传到达即启动，
 * phoneCall 类型前台服务 + CallStyle 通知（后台/锁屏/息屏可达；
 * Android 12+ 依赖既有保活前台服务豁免后台 FGS 启动限制）。
 * 终止：Flutter 接管（dismiss）/ 拒绝 / 60s 无响应超时。
 */
class CallForegroundService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val video = intent?.getBooleanExtra(EXTRA_VIDEO, false) ?: false
        val notification = CallNotificationManager.buildIncoming(this, video)
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(
                CallNotificationManager.notificationId,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL,
            )
        } else {
            startForeground(CallNotificationManager.notificationId, notification)
        }
        Handler(mainLooper).postDelayed({ stopSelfSafely() }, RING_TIMEOUT_MS)
        return START_NOT_STICKY
    }

    private fun stopSelfSafely() {
        CallNotificationManager.cancel(this)
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    companion object {
        const val EXTRA_VIDEO = "video"
        private const val RING_TIMEOUT_MS = 60_000L

        fun start(context: Context, video: Boolean) {
            val intent = Intent(context, CallForegroundService::class.java)
                .putExtra(EXTRA_VIDEO, video)
            try {
                ContextCompat.startForegroundService(context, intent)
            } catch (_: Exception) {
                // Android 12+ 后台启动受限且无豁免：退化直接发 CallStyle
                // 通知（无前台服务，锁屏全屏仍可用）。
                val nm = context.getSystemService(Context.NOTIFICATION_SERVICE)
                    as android.app.NotificationManager
                nm.notify(
                    CallNotificationManager.notificationId,
                    CallNotificationManager.buildIncoming(context, video),
                )
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, CallForegroundService::class.java))
            CallNotificationManager.cancel(context)
        }
    }
}
