package com.liuhetong.mobile

import android.app.Application

/**
 * 个推两段式初始化的第一段（官方合规模式）：
 *
 * preInit 与 initialize 均要求已持久化同意隐私政策。
 * 已同意用户在 Application 中保留准备步骤；首次同意后由
 * `chatflow/getui` 通道按 preInit → initialize 补齐（docs/PUSH_SETUP.md）。
 *
 * Release 构建绝不挂调试日志（demo 明示"切勿在 release 版本上开启调试日志"）。
 */
class ChatFlowApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        GetuiConsent.preInitialize(this)
    }
}
