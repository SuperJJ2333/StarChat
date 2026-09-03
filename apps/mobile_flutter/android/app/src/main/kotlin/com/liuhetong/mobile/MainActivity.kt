package com.liuhetong.mobile

import android.content.Intent
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import me.leolin.shortcutbadger.ShortcutBadger

/// 桌面角标通道（PRD §35）：Dart 侧 BadgeService 经此设置启动器角标。
/// 厂商启动器差异由 ShortcutBadger 适配；不支持时静默降级，不报错。
class MainActivity : FlutterActivity() {
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
    }
}
