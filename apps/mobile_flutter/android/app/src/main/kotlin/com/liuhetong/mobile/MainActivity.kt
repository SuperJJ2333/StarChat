package com.liuhetong.mobile

import android.content.Intent
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import me.leolin.shortcutbadger.ShortcutBadger

/// 桌面角标通道（PRD §35）：Dart 侧 BadgeService 经此设置启动器角标。
/// 厂商启动器差异由 ShortcutBadger 适配；不支持时静默降级，不报错。
class MainActivity : FlutterActivity() {
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
