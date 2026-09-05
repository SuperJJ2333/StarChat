package com.liuhetong.mobile.call

/**
 * Flutter 业务处理器未就绪（引擎未起 / AppHome 尚未完成 ready 握手）时
 * 的待处理通话动作暂存（冷启动交接，规格§五）。
 *
 * - 只保存 关联标识(callId) / 动作(answer|reject) / 时间 / 消费状态——
 *   不含任何敏感明文（无来电内容、无账号信息、无房间号）；
 * - [drain] 取出即标记消费（一次动作只重放一次）；
 * - 超龄（[MAX_AGE_MS]）动作清除后丢弃——冷启动耗时过长时用户动作
 *   不再可信，绝不应用到之后到达的新通话；
 * - 进程内暂存（进程死亡即清空）：进程死亡时通知已随系统回收，
 *   用户的接听/拒绝经通知按钮广播重新拉起进程并再次进入本队列。
 */
object PendingCallActions {
    const val ACTION_ANSWER = "answer"
    const val ACTION_REJECT = "reject"

    private const val MAX_AGE_MS = 30_000L
    private const val MAX_KEEP = 8

    data class Action(
        val callId: String?,
        val action: String,
        val atMs: Long,
        var consumed: Boolean = false,
    )

    private val actions = mutableListOf<Action>()

    /** 暂存动作；同一通话同类动作去重（重复点击只保留最新）。 */
    @Synchronized
    fun store(callId: String?, action: String) {
        actions.removeAll {
            it.callId == callId && it.action == action && !it.consumed
        }
        actions.add(Action(callId, action, System.currentTimeMillis()))
        while (actions.size > MAX_KEEP) actions.removeAt(0)
    }

    /**
     * 取出全部未消费且未过期的动作并标记消费；过期动作清除丢弃。
     */
    @Synchronized
    fun drain(): List<Action> {
        val now = System.currentTimeMillis()
        actions.removeAll { now - it.atMs > MAX_AGE_MS }
        val due = actions.filter { !it.consumed }
        due.forEach { it.consumed = true }
        return due.toList()
    }

    /** 单元测试注入当前时间。 */
    internal fun drainAt(nowMs: Long): List<Action> {
        actions.removeAll { nowMs - it.atMs > MAX_AGE_MS }
        val due = actions.filter { !it.consumed }
        due.forEach { it.consumed = true }
        return due.toList()
    }

    @Synchronized
    fun clear() = actions.clear()
}
