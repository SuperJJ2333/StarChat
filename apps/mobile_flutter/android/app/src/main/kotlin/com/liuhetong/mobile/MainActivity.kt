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
                    GetuiBridgeState.onEvent = { event ->
                        // 立即回放当前 CID（若有），再接后续变更。
                        GetuiBridgeState.currentCid()?.let {
                            events.success(mapOf("type" to "cid", "cid" to it))
                        }
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
                acquire()
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

    override fun onDestroy() {
        releaseWakeLocks()
        super.onDestroy()
    }
}
