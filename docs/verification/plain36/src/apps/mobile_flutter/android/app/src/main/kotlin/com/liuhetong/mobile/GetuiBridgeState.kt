package com.liuhetong.mobile

import android.os.Handler
import android.os.Looper

/**
 * 个推状态桥（原生回调 → Dart EventChannel）。
 *
 * 线程模型：SDK 回调在其后台线程；Dart 事件必须在主线程投递。
 * 日志红线：CID 等标识绝不打印。
 */
object GetuiBridgeState {
    @Volatile
    private var cid: String? = null

    @Volatile
    private var online: Boolean? = null

    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    var onEvent: ((Map<String, String?>) -> Unit)? = null

    fun currentCid(): String? = cid

    fun updateCid(value: String?) {
        cid = value
        emit(mapOf("type" to "cid", "cid" to value))
    }

    fun updateOnline(value: Boolean) {
        online = value
        emit(mapOf("type" to "online", "online" to value.toString()))
    }

    fun notifyClicked(kind: String) {
        emit(mapOf("type" to "clicked", "kind" to kind))
    }

    private fun emit(event: Map<String, String?>) {
        val listener = onEvent ?: return
        mainHandler.post { listener(event) }
    }
}
