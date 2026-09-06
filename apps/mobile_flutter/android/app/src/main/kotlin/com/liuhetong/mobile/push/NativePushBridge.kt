package com.liuhetong.mobile.push

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.content.SharedPreferences
import io.flutter.plugin.common.MethodChannel

/**
 * 原生推送 → Flutter 桥（规格：NativePushBridge 的 Android 侧）。
 *
 * Persist only bounded, short-lived wake categories, then deliver after Dart
 * registers its listener. No message, room, caller or call state is stored here.
 * Android may reject a background launch; the wake remains for the next start.
 */
object NativePushBridge {
    const val channelName = "chatflow/push"
    const val eventPushMessage = "pushMessage"
    const val eventFriendRequest = "friendRequest"

    @Volatile private var channel: MethodChannel? = null
    private val handler = Handler(Looper.getMainLooper())
    private val events = listOf(eventPushMessage, eventFriendRequest)
    private val inFlight = mutableMapOf<String, Long>()
    private var preferences: SharedPreferences? = null
    private var ready = false
    private var epoch = 0L
    private const val ttlMs = 120_000L

    fun setUp(messenger: io.flutter.plugin.common.BinaryMessenger, context: Context? = null) {
        teardown()
        if (context != null) preferences = store(context)
        val next = MethodChannel(messenger, channelName)
        channel = next
        next.setMethodCallHandler { call, result ->
            when (call.method) {
                "pushListenerReady" -> {
                    ready = true
                    result.success(true)
                    drain()
                }
                "pushListenerStopped" -> {
                    ready = false
                    epoch++
                    inFlight.clear()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    fun notifyFlutter(context: Context, event: String) {
        if (event !in events) return
        val app = context.applicationContext
        handler.post {
            val prefs = store(app)
            preferences = prefs
            val now = System.currentTimeMillis()
            val previous = prefs.getLong(event, 0)
            val revision = if (previous in now..(now + ttlMs)) previous + 1 else now
            prefs.edit().putLong(event, revision).apply()
            if (channel == null) launchApp(app)
            drain()
        }
    }

    private fun store(context: Context) =
        context.applicationContext.getSharedPreferences("pending_push_wakes", Context.MODE_PRIVATE)

    private fun drain() {
        val owner = channel ?: return
        if (!ready) return
        val prefs = preferences ?: return
        val now = System.currentTimeMillis()
        for (event in events) {
            val revision = prefs.getLong(event, 0)
            if (revision == 0L || inFlight.containsKey(event)) continue
            if (revision < now - ttlMs || revision > now + ttlMs) {
                prefs.edit().remove(event).apply()
                continue
            }
            inFlight[event] = revision
            val deliveryEpoch = epoch
            owner.invokeMethod(event, null, object : MethodChannel.Result {
                override fun success(result: Any?) = finish(result == true)
                override fun error(code: String, message: String?, details: Any?) = finish(false)
                override fun notImplemented() = finish(false)
                private fun finish(acknowledged: Boolean) {
                    handler.post {
                        if (channel !== owner || epoch != deliveryEpoch || inFlight[event] != revision) return@post
                        inFlight.remove(event)
                        if (!acknowledged) return@post // retry on next readiness/wake, never spin
                        if (prefs.getLong(event, 0) == revision) {
                            prefs.edit().remove(event).apply()
                        }
                        drain()
                    }
                }
            })
        }
    }

    private fun launchApp(context: Context) {
        try {
            context.packageManager.getLaunchIntentForPackage(context.packageName)
                ?.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
                ?.let { context.startActivity(it) }
        } catch (_: RuntimeException) {
            // Background launch restrictions must not crash the SDK callback.
        }
    }

    fun teardown() {
        channel?.setMethodCallHandler(null)
        channel = null
        ready = false
        epoch++
        inFlight.clear()
    }
}
