package com.liuhetong.mobile

import android.app.Application
import com.igexin.sdk.PushManager

/**
 * 个推两段式初始化的第一段（官方合规模式）：
 *
 * preInit 在隐私政策同意前即可调用——只做本地准备，不采集、不联网；
 * 真正的 initialize 由 Dart 侧在用户持久化同意隐私政策之后，经
 * `chatflow/getui` 通道显式触发（docs/PUSH_SETUP.md）。
 *
 * Release 构建绝不挂调试日志（demo 明示"切勿在 release 版本上开启调试日志"）。
 */
class ChatFlowApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        try {
            PushManager.getInstance().preInit(this)
        } catch (_: Throwable) {
            // 推送仅是增强通道：初始化失败绝不影响聊天主流程。
        }
    }
}
