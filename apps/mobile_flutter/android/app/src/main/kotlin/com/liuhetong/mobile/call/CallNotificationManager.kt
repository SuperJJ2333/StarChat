package com.liuhetong.mobile.call

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.pm.PackageManager
import android.content.Intent
import android.os.Build
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import android.net.Uri
import androidx.core.content.ContextCompat

/**
 * 来电通知（规格§2/§3）：calls_ring 渠道（importance=max、系统铃声、
 * category=call）+ Android 13+ Notification.CallStyle.forIncomingCall 系
 * 统级接听/拒绝按钮；API<31 回退 fullScreenIntent + 自绘按钮。
 * 通知 ID 与 Flutter 侧来电通知一致（41001）——两路互替不叠加。
 */
object CallNotificationManager {
    const val channelId = "calls_ring"
    const val notificationId = 41001
    private const val rawRingtone = "chatflow_ringtone"

    const val actionAnswer = "com.liuhetong.mobile.call.ANSWER"
    const val actionReject = "com.liuhetong.mobile.call.REJECT"

    fun ensureChannel(context: Context) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val sound = Uri.parse("android.resource://${context.packageName}/raw/$rawRingtone")
        val channel = NotificationChannel(
            channelId, "通话提醒",
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "系统级来电提醒（响铃/锁屏全屏）"
            setSound(sound, android.media.AudioAttributes.Builder()
                .setUsage(android.media.AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                .setContentType(android.media.AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build())
            enableVibration(true)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            setBypassDnd(true)
        }
        nm.createNotificationChannel(channel)
    }

    /** CallStyle 需要：MANAGE_OWN_CALLS 权限 + 已注册 PhoneAccount（API31+）。 */
    private fun ensurePhoneAccount(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < 31) return false
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.MANAGE_OWN_CALLS)
            != PackageManager.PERMISSION_GRANTED
        ) return false
        return try {
            val telecom = context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
            val handle = phoneAccountHandle(context)
            val registered = telecom.getPhoneAccount(handle) != null
            if (!registered) {
                val account = android.telecom.PhoneAccount.Builder(handle, "畅聊")
                    .setCapabilities(android.telecom.PhoneAccount.CAPABILITY_SELF_MANAGED)
                    .build()
                telecom.registerPhoneAccount(account)
            }
            telecom.getPhoneAccount(handle) != null
        } catch (_: Exception) {
            false
        }
    }

    private fun phoneAccountHandle(context: Context): PhoneAccountHandle =
        PhoneAccountHandle(
            android.content.ComponentName(context, CallConnectionService::class.java),
            "chatflow_calls",
        )

    /**
     * 全屏/正文展示意图：指向 CallActivity（仅展示来电页）。
     * 修复：此前 fullScreenIntent/contentIntent 复用[接听]广播——
     * 点通知正文或系统全屏展示即等于接听（规格§六1/§六2 禁止）。
     */
    private fun showPendingIntent(context: Context): PendingIntent =
        PendingIntent.getActivity(
            context, 3,
            Intent(context, CallActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

    /**
     * Android 14+ 全屏通知授权检查：未授权时系统自动降级为横幅通知，
     * 应用不得伪称必定全屏；提供设置入口（见 [openFullScreenIntentSettings]）。
     */
    fun canUseFullScreenIntent(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < 34) return true
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        return nm.canUseFullScreenIntent()
    }

    /** Android 14+ 全屏通知授权设置页（CallActivity 的"去授权"入口）。 */
    fun openFullScreenIntentSettings(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < 34) return false
        return try {
            context.startActivity(
                Intent(android.provider.Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT)
                    .setData(Uri.parse("package:${context.packageName}"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            true
        } catch (_: Exception) {
            false
        }
    }

    fun buildIncoming(context: Context, video: Boolean): Notification {
        ensureChannel(context)
        val person = android.app.Person.Builder()
            .setName(if (video) "畅聊视频来电" else "语音通话")
            .setImportant(true)
            .build()
        val answerPi = PendingIntent.getBroadcast(
            context, 0,
            Intent(context, IncomingCallReceiver::class.java).setAction(actionAnswer),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val rejectPi = PendingIntent.getBroadcast(
            context, 1,
            Intent(context, IncomingCallReceiver::class.java).setAction(actionReject),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        // 正文点击 = 打开来电展示页（不接听）。
        val showPi = showPendingIntent(context)
        val base = Notification.Builder(context, channelId)
            .setSmallIcon(context.applicationInfo.icon)
            .setContentTitle(if (video) "畅聊视频来电" else "语音通话")
            .setContentText("加密来电")
            .setCategory(Notification.CATEGORY_CALL)
            .setContentIntent(showPi)
            .setOngoing(true)
            .setAutoCancel(false)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
        // 审计 P1（gallery-call-review）：全屏意图在**共同路径**配置——
        // CallStyle 只是样式/动作模板，不会自动生成打开 CallActivity 的
        // fullScreenIntent；此前仅回退分支设置，API31+ 正常分支缺失锁屏
        // 全屏入口。仍指向展示 Activity（绝不接听）；未授权（Android 14+）
        // 时系统自动降级横幅（canUseFullScreenIntent 见 CallActivity 内
        // 引导）。
        if (canUseFullScreenIntent(context)) {
            base.setFullScreenIntent(showPi, true)
        }
        if (Build.VERSION.SDK_INT >= 31 && ensurePhoneAccount(context)) {
            // CallStyle 分支：系统级来电样式，
            // hangup=拒绝、answer=接听（参数顺序：person, hangup, answer）。
            base.setStyle(Notification.CallStyle.forIncomingCall(person, rejectPi, answerPi))
        } else {
            // 回退分支：显式接听/拒绝按钮（CallStyle 之外的兼容路径）。
            base.addAction(0, "接听", answerPi)
                .addAction(0, "拒绝", rejectPi)
        }
        return base.build()
    }

    fun cancel(context: Context) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.cancel(notificationId)
    }
}
