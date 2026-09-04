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
            channelId, "来电铃声",
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

    fun buildIncoming(context: Context, video: Boolean): Notification {
        ensureChannel(context)
        val person = android.app.Person.Builder()
            .setName(if (video) "畅聊视频来电" else "畅聊语音来电")
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
        val contentPi = PendingIntent.getBroadcast(
            context, 2,
            Intent(context, IncomingCallReceiver::class.java).setAction(actionAnswer),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val base = Notification.Builder(context, channelId)
            .setSmallIcon(context.applicationInfo.icon)
            .setContentTitle(if (video) "畅聊视频来电" else "畅聊语音来电")
            .setContentText("加密来电")
            .setCategory(Notification.CATEGORY_CALL)
            .setContentIntent(answerPi)
            .setOngoing(true)
            .setAutoCancel(false)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
        if (Build.VERSION.SDK_INT >= 31 && ensurePhoneAccount(context)) {
            base.setStyle(Notification.CallStyle.forIncomingCall(person, rejectPi, answerPi))
        } else {
            // 回退：全屏意图（锁屏/息屏点亮）+ 显式接听/拒绝按钮。
            base.setFullScreenIntent(answerPi, true)
                .addAction(0, "接听", answerPi)
                .addAction(0, "拒绝", rejectPi)
        }
        return base.build()
    }

    fun cancel(context: Context) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.cancel(notificationId)
    }
}
