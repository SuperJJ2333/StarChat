package com.liuhetong.mobile.call

import android.telecom.Connection
import android.telecom.ConnectionService

/**
 * 无操作 ConnectionService：仅为满足 Notification.CallStyle 的
 * PhoneAccount 注册要求（PhoneAccount 需挂 ConnectionService 组件）。
 * 通话媒体/信令全部留在 Flutter（Matrix CallSession/WebRTC）——
 * 本类不创建任何真实 Connection。
 */
class ChatFlowConnectionService : ConnectionService() {
    // 有意无实现：CallStyle 展示仅要求 PhoneAccount 存在；
    // 绝不经由 Telecom 建立通话（不把 WebRTC 挪到 Native）。
}
