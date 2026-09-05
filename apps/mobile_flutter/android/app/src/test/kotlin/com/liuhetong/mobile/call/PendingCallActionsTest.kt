package com.liuhetong.mobile.call

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * PendingCallActions（冷启动待处理动作暂存）单元测试：
 * 暂存/消费一次/过期丢弃/同通话去重。
 */
class PendingCallActionsTest {

    @Test
    fun `drain returns stored actions once and marks consumed`() {
        PendingCallActions.clear()
        val t0 = System.currentTimeMillis()
        PendingCallActions.store("call-a", PendingCallActions.ACTION_ANSWER)
        // 未过期：可取出且只取出一次。
        val first = PendingCallActions.drainAt(t0 + 1_000)
        assertEquals(1, first.size)
        assertEquals("call-a", first.first().callId)
        assertEquals(PendingCallActions.ACTION_ANSWER, first.first().action)
        val second = PendingCallActions.drainAt(t0 + 2_000)
        assertTrue(second.isEmpty(), "动作取出即标记消费，不得重复重放")
    }

    @Test
    fun `expired actions are discarded not replayed`() {
        PendingCallActions.clear()
        val t0 = System.currentTimeMillis()
        PendingCallActions.store("call-b", PendingCallActions.ACTION_REJECT)
        // 超过 30s 未被消费：清除丢弃（冷启动耗时过长动作不再可信）。
        val drained = PendingCallActions.drainAt(t0 + 31_000)
        assertTrue(drained.isEmpty(), "过期动作必须丢弃，不得应用到之后的通话")
        // 之后的新通话不受影响。
        PendingCallActions.store("call-c", PendingCallActions.ACTION_ANSWER)
        val fresh = PendingCallActions.drainAt(t0 + 32_000)
        assertEquals(listOf("call-c"), fresh.map { it.callId })
    }

    @Test
    fun `duplicate taps for same call and action keep only latest`() {
        PendingCallActions.clear()
        PendingCallActions.store("call-d", PendingCallActions.ACTION_ANSWER)
        PendingCallActions.store("call-d", PendingCallActions.ACTION_ANSWER)
        PendingCallActions.store("call-d", PendingCallActions.ACTION_ANSWER)
        val drained = PendingCallActions.drainAt(System.currentTimeMillis())
        assertEquals(1, drained.size, "重复点击同一通话同一动作只保留最新一条")
        // 不同动作（先接听后拒绝）各自保留：以到达顺序重放，Flutter 侧
        // 按相位幂等处理。
        PendingCallActions.store("call-e", PendingCallActions.ACTION_ANSWER)
        PendingCallActions.store("call-e", PendingCallActions.ACTION_REJECT)
        assertEquals(
            2,
            PendingCallActions.drainAt(System.currentTimeMillis()).size,
        )
    }
}
