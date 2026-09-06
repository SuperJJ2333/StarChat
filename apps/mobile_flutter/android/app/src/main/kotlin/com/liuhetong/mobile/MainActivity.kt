package com.liuhetong.mobile

import android.content.Intent
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import com.igexin.sdk.PushManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import me.leolin.shortcutbadger.ShortcutBadger

/// 桌面角标通道（PRD §35）：Dart 侧 BadgeService 经此设置启动器角标。
/// 厂商启动器差异由 ShortcutBadger 适配；不支持时静默降级，不报错。
class MainActivity : FlutterActivity() {
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 原生推送桥。
        com.liuhetong.mobile.push.NativePushBridge.setUp(
            flutterEngine.dartExecutor.binaryMessenger,
            applicationContext,
        )
        // 原生通话桥（修复初始化顺序：先创建 native_call 通道再注册处理器
        // ——此前 setCallHandler 先于通道创建执行，channel 为 null 时注册
        // 是空操作，answerCall/rejectCall/endCall/getActiveCall 全部不可达；
        // 且 CallManager 监听器在 setUp 内注册、teardown 内移除，重建不泄漏）。
        com.liuhetong.mobile.call.NativeCallBridge.setUp(
            applicationContext,
            flutterEngine.dartExecutor.binaryMessenger,
            com.liuhetong.mobile.call.NativeCallBridge.CallHandlers(
                onAnswer = {
                    com.liuhetong.mobile.call.CallManager.onAnswerRequested()
                    com.liuhetong.mobile.call.CallManager
                        .launchCallActivity(applicationContext)
                },
                onReject = {
                    com.liuhetong.mobile.call.CallManager.onRejectRequested()
                },
                onEnd = {
                    com.liuhetong.mobile.call.CallManager.onEnded()
                },
            ),
        )
        com.liuhetong.mobile.call.CallBridge.setUp(
            flutterEngine.dartExecutor.binaryMessenger,
        ) {
            // Flutter 已接管通话呈现：收起铃声服务与通知（保留状态）。
            com.liuhetong.mobile.call.CallManager.dismissPresentation()
        }
        // 个推桥（隐私红线：不打印 CID/载荷；initialize 仅在用户同意后由 Dart 触发）。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "chatflow/getui")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "initialize" -> {
                        // 第二段初始化：preInit 已在 Application.onCreate（同意前安全）完成。
                        try {
                            PushManager.getInstance().initialize(this)
                            result.success(true)
                        } catch (_: Exception) {
                            result.success(false)
                        }
                    }
                    "getCid" -> result.success(GetuiBridgeState.currentCid())
                    "isPushEnabled" -> {
                        try {
                            result.success(PushManager.getInstance().isPushTurnedOn(this))
                        } catch (_: Exception) {
                            result.success(false)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "chatflow/getui/events")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    // CID 竞态修复：onListen 时立即回放当前 CID（若有）。
                    // 此前回放代码在 onEvent lambda 内部——CID 已存在但无新
                    // 事件时 Dart 永远收不到，pusher 整个会话不注册。
                    GetuiBridgeState.currentCid()?.let { cid ->
                        events.success(mapOf("type" to "cid", "cid" to cid))
                    }
                    GetuiBridgeState.onEvent = { event ->
                        events.success(event)
                    }
                }

                override fun onCancel(arguments: Any?) {
                    GetuiBridgeState.onEvent = null
                }
            })
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "chatflow/badge")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "updateCount" -> {
                        val count = call.argument<Int>("count") ?: 0
                        try {
                            ShortcutBadger.applyCount(applicationContext, count)
                            result.success(true)
                        } catch (_: Exception) {
                            result.success(false)
                        }
                    }
                    "clear" -> {
                        try {
                            ShortcutBadger.removeCount(applicationContext)
                            result.success(true)
                        } catch (_: Exception) {
                            result.success(false)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "chatflow/gallery")
            .setMethodCallHandler { call, result ->
                if (call.method == "androidSdk") result.success(android.os.Build.VERSION.SDK_INT)
                else result.notImplemented()
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "chatflow/notification")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // PRD §56：权限被拒后的降级路径——直达本应用通知设置页
                    // （Android 13+ 二次拒绝后系统弹窗不再出现）。
                    "openNotificationSettings" -> {
                        try {
                            val intent = Intent(
                                Settings.ACTION_APP_NOTIFICATION_SETTINGS
                            ).putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                            startActivity(intent)
                            result.success(true)
                        } catch (_: Exception) {
                            result.success(false)
                        }
                    }
                    // 直达具体通知渠道设置页：渠道重要性/声音创建后不可由
                    // 应用修改，用户静音了 v2 消息渠道时只能引导到此修改。
                    "openChannelSettings" -> {
                        val channelId = call.argument<String>("channelId")
                        if (channelId == null) {
                            result.error("invalid_args", "channelId required", null)
                        } else {
                            try {
                                val intent = Intent(
                                    Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS
                                )
                                    .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                                    .putExtra(Settings.EXTRA_CHANNEL_ID, channelId)
                                startActivity(intent)
                                result.success(true)
                            } catch (_: Exception) {
                                result.success(false)
                            }
                        }
                    }
                    // 渠道真实状态（用户可能手动改过重要性/声音）：
                    // 诊断日志与设置页展示用。
                    "getCallPermissionReadiness" -> {
                        val nm = getSystemService(android.app.NotificationManager::class.java)
                        fun granted(permission: String) =
                            androidx.core.content.ContextCompat.checkSelfPermission(this, permission) ==
                                android.content.pm.PackageManager.PERMISSION_GRANTED
                        fun channelReady(id: String, minimum: Int): Boolean? {
                            if (Build.VERSION.SDK_INT < 26) return true
                            val channel = nm.getNotificationChannel(id) ?: return null
                            return channel.importance >= minimum
                        }
                        result.success(mapOf(
                            "android" to true,
                            "microphone" to granted(android.Manifest.permission.RECORD_AUDIO),
                            "camera" to granted(android.Manifest.permission.CAMERA),
                            "notifications" to androidx.core.app.NotificationManagerCompat.from(this).areNotificationsEnabled(),
                            "callChannel" to channelReady("calls_ring", android.app.NotificationManager.IMPORTANCE_HIGH),
                            "ongoingChannel" to channelReady("chatflow_silent", android.app.NotificationManager.IMPORTANCE_MIN),
                            "fullScreenRequired" to (Build.VERSION.SDK_INT >= 34),
                            "fullScreen" to (Build.VERSION.SDK_INT < 34 || nm.canUseFullScreenIntent()),
                            "overlay" to (Build.VERSION.SDK_INT < 23 || Settings.canDrawOverlays(this))
                        ))
                    }
                    "openOverlaySettings" -> {
                        try {
                            startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                Uri.parse("package:$packageName")))
                            result.success(true)
                        } catch (_: Exception) { result.success(false) }
                    }
                    "getNotificationReadiness" -> {
                        val nm = getSystemService(android.app.NotificationManager::class.java)
                        val issues = mutableListOf<String>()
                        if (!androidx.core.app.NotificationManagerCompat.from(this).areNotificationsEnabled()) {
                            issues.add("通知未授权")
                        }
                        if (android.os.Build.VERSION.SDK_INT >= 26) {
                            for ((id, label) in listOf("chatflow_messages_v2" to "消息", "calls_ring" to "来电")) {
                                val channel = nm.getNotificationChannel(id) ?: continue
                                if (channel.importance == 0) issues.add("${label}提醒已关闭")
                                else if (channel.sound == null) issues.add("${label}铃声已关闭")
                            }
                        }
                        val fullScreenDenied = android.os.Build.VERSION.SDK_INT >= 34 && !nm.canUseFullScreenIntent()
                        if (fullScreenDenied) issues.add("锁屏来电未授权")
                        result.success(mapOf("issues" to issues, "fullScreenDenied" to fullScreenDenied))
                    }
                    "openFullScreenSettings" -> {
                        try {
                            if (android.os.Build.VERSION.SDK_INT >= 34) {
                                startActivity(Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT,
                                    android.net.Uri.parse("package:$packageName")))
                            } else {
                                startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                    android.net.Uri.parse("package:$packageName")))
                            }
                            result.success(true)
                        } catch (_: Exception) { result.success(false) }
                    }
                    "getChannelState" -> {
                        val channelId = call.argument<String>("channelId")
                        if (channelId == null) {
                            result.error("invalid_args", "channelId required", null)
                        } else {
                            try {
                                val nm = getSystemService(android.app.NotificationManager::class.java)
                                val channel = nm.getNotificationChannel(channelId)
                                if (channel == null) {
                                    result.success(mapOf("exists" to false))
                                } else {
                                    result.success(
                                        mapOf(
                                            "exists" to true,
                                            "importance" to channel.importance,
                                            "sound" to (channel.sound?.toString() ?: ""),
                                            "vibration" to channel.shouldVibrate(),
                                            "canBypassDnd" to channel.canBypassDnd()
                                        )
                                    )
                                }
                            } catch (_: Exception) {
                                result.success(mapOf("exists" to false))
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        // 后台/锁屏消息保活（BUG2 加固）：dataSync 前台服务只提升进程
        // 优先级，不阻止息屏后 CPU 休眠与 WiFi 低功耗断连——长轮询同步
        // 仍会停。此通道在保活期间持有 PARTIAL WakeLock + 高性能
        // WifiLock，并提供电池优化白名单引导（厂商 ROM 清理的必要条件）。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "chatflow/keepalive")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "acquireWakeLocks" -> {
                        try {
                            acquireWakeLocks()
                            result.success(true)
                        } catch (_: Exception) {
                            result.success(false)
                        }
                    }
                    "releaseWakeLocks" -> {
                        try {
                            releaseWakeLocks()
                            result.success(true)
                        } catch (_: Exception) {
                            result.success(false)
                        }
                    }
                    "isIgnoringBatteryOptimizations" -> {
                        try {
                            val pm = getSystemService(PowerManager::class.java)
                            result.success(pm.isIgnoringBatteryOptimizations(packageName))
                        } catch (_: Exception) {
                            result.success(false)
                        }
                    }
                    "requestIgnoreBatteryOptimizations" -> {
                        try {
                            startActivity(
                                Intent(
                                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                    Uri.parse("package:$packageName")
                                )
                            )
                            result.success(true)
                        } catch (_: Exception) {
                            result.success(false)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun acquireWakeLocks() {
        if (wakeLock?.isHeld != true) {
            val pm = getSystemService(PowerManager::class.java)
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "chatflow:sync").apply {
                setReferenceCounted(false)
                // C05：带超时持有（20 分钟）——泄漏时自释放；Dart 看门狗
                // 每 10 分钟重申，正常运行不会到期。
                acquire(20 * 60 * 1000L)
            }
        }
        if (wifiLock?.isHeld != true) {
            val wifi = applicationContext.getSystemService(WifiManager::class.java)
            // API 34+ 用低时延模式；低版本用高性能模式防 WiFi 息屏休眠。
            val mode = if (Build.VERSION.SDK_INT >= 34) {
                WifiManager.WIFI_MODE_FULL_LOW_LATENCY
            } else {
                WifiManager.WIFI_MODE_FULL_HIGH_PERF
            }
            wifiLock = wifi.createWifiLock(mode, "chatflow:sync").apply {
                setReferenceCounted(false)
                acquire()
            }
        }
    }

    private fun releaseWakeLocks() {
        try {
            wakeLock?.takeIf { it.isHeld }?.release()
        } catch (_: Exception) {
        }
        try {
            wifiLock?.takeIf { it.isHeld }?.release()
        } catch (_: Exception) {
        }
    }

    // Flutter has already handled child routes before requesting a system pop.
    // Preserve the engine/session when Back reaches the app root (also pre-31).
    override fun popSystemNavigator(): Boolean {
        moveTaskToBack(true)
        return true
    }

    override fun onDestroy() {
        releaseWakeLocks()
        super.onDestroy()
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        // 引擎销毁：移除通道处理器与 CallManager 监听（防泄漏/防重复注册）。
        com.liuhetong.mobile.call.CallBridge.teardown()
        com.liuhetong.mobile.call.NativeCallBridge.teardown()
        com.liuhetong.mobile.push.NativePushBridge.teardown()
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
