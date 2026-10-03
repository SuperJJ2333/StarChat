package com.liuhetong.mobile.push

import android.app.NotificationManager
import android.content.Context
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import kotlin.test.*

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], application = android.app.Application::class, manifest = Config.NONE)
class NativeMessageNotificationsTest {
    private val app get() = RuntimeEnvironment.getApplication()
    private lateinit var owner: NativeMessageOwner
    private lateinit var scope: String
    private val room = "b".repeat(64)
    private val event = "c".repeat(64)
    @Before fun before() {
        app.deleteDatabase("native_messages.db")
        owner = NativeMessageOwner(app)
        scope = owner.bind("a".repeat(64))
        assertTrue(owner.install(mapOf("scope" to scope, "revision" to 1L,
            "enabled" to true, "sound" to true, "vibration" to true,
            "dnd" to false, "start" to 1380, "end" to 480,
            "rooms" to mapOf(room to false))))
    }
    @After fun after() { owner.close() }
    private fun receive(key: String = event) = owner.receive(scope, room, key)
    private fun notifications() = app.getSystemService(NotificationManager::class.java).activeNotifications

    @Test fun coldReceivePostsGenericWithoutStartingActivityAndDeduplicates() {
        receive(); receive()
        assertEquals(1, notifications().size)
        assertNull(shadowOf(app).nextStartedActivity)
        assertFalse(owner.claim(scope, room, event))
        assertEquals("您有一条新消息", notifications()[0].notification.extras.getString("android.text"))
    }
    @Test fun persistedSessionSurvivesColdRestartButRevocationRejectsOldPushAndTap() {
        owner.close(); owner = NativeMessageOwner(app)
        assertEquals(scope, owner.bind("a".repeat(64)))
        receive()
        assertEquals(1, notifications().size)
        owner.revoke()
        receive()
        assertTrue(notifications().isEmpty())
        assertFalse(owner.tap(scope, room, event))
        assertNotEquals(scope, owner.bind("d".repeat(64)))
    }
    @Test fun muteAndSoundSettingsChooseQuietChannelsAndGlobalOffSuppresses() {
        assertTrue(owner.install(mapOf("scope" to scope, "revision" to 2L,
            "enabled" to true, "sound" to false, "vibration" to true,
            "dnd" to false, "start" to 1380, "end" to 480,
            "rooms" to mapOf(room to false))))
        receive()
        assertEquals("chatflow_messages_vibrate_v1", notifications()[0].notification.channelId)
        owner.invalidate(scope)
        owner.receive(scope, room, "e".repeat(64))
        assertTrue(notifications().isEmpty())
    }
    @Test fun matrixFirstClaimPreventsReceiveAndStaleRevisionCannotReplacePolicy() {
        assertTrue(owner.claim(scope, room, event))
        owner.complete(scope, event)
        receive()
        assertTrue(notifications().isEmpty())
        assertFalse(owner.install(mapOf("scope" to scope, "revision" to 0L)))
    }
    @Test fun unknownRoomIsSilentAndOnlyExplicitCurrentScopeTapIsAccepted() {
        owner.receive(scope, "e".repeat(64), event)
        assertEquals("chatflow_silent", notifications()[0].notification.channelId)
        assertFalse(owner.tap("f".repeat(64), room, event))
        assertTrue(owner.tap(scope, "e".repeat(64), event))
        assertEquals(scope, owner.takeTap()?.get("scope"))
        assertNull(owner.takeTap())
    }
    @Test fun decryptedPreviewReplacesOnlySameVisibleEventWithoutSecondAlert() {
        receive()
        assertFalse(owner.resolve(scope, room, event, true, false, "Alice", "Local preview"))
        val notification = notifications().single().notification
        assertEquals("Local preview", notification.extras.getString("android.text"))
        assertTrue(notification.flags and android.app.Notification.FLAG_ONLY_ALERT_ONCE != 0)
        app.getSystemService(NotificationManager::class.java).cancelAll()
        owner.resolve(scope, room, event, true, false, "Alice", "Must stay dismissed")
        assertTrue(notifications().isEmpty())
    }
    @Test fun newerEventInRoomCannotBeReplacedByOlderCatchup() {
        receive()
        receive("d".repeat(64))
        owner.resolve(scope, room, event, true, false, "Old", "Old preview")
        assertEquals("您有一条新消息", notifications().single().notification.extras.getString("android.text"))
    }
    @Test fun restrictiveInvalidSnapshotAndStaleInstallCannotRestoreSound() {
        receive()
        owner.invalidate(scope, 4)
        assertFalse(owner.install(mapOf("scope" to scope, "revision" to 3L,
            "enabled" to true, "sound" to true, "vibration" to true,
            "dnd" to false, "start" to 1380, "end" to 480, "rooms" to mapOf(room to false))))
        receive("d".repeat(64))
        assertTrue(notifications().isEmpty())
        assertFalse(owner.install(mapOf("scope" to scope, "revision" to 4L)))
        receive("e".repeat(64))
        assertTrue(notifications().isEmpty())
    }
    @Test fun expiredReservationFallsBackAndLateCompletionCannotClaimDisplayedEvent() {
        assertTrue(owner.claim(scope, room, event))
        app.openOrCreateDatabase("native_messages.db", 0, null).use {
            it.execSQL("UPDATE claims SET at=? WHERE key=?", arrayOf<Any>(System.currentTimeMillis() - 6000, event))
        }
        owner.retryPending()
        assertEquals(1, notifications().size)
        owner.complete(scope, event)
        assertFalse(owner.claim(scope, room, event))
    }
    @Test fun deniedPermissionIsRetryableAndNotMarkedDisplayed() {
        shadowOf(app.getSystemService(NotificationManager::class.java)).setNotificationsEnabled(false)
        receive()
        assertTrue(notifications().isEmpty())
        shadowOf(app.getSystemService(NotificationManager::class.java)).setNotificationsEnabled(true)
        owner.retryPending()
        assertEquals(1, notifications().size)
    }
    @Test fun unknownOverflowPolicyAndDndRemainNonDisruptive() {
        val c = java.util.Calendar.getInstance()
        val nowMinute = c.get(java.util.Calendar.HOUR_OF_DAY) * 60 + c.get(java.util.Calendar.MINUTE)
        val start = (nowMinute + 1439) % 1440
        val end = (nowMinute + 1) % 1440
        assertTrue(owner.install(mapOf("scope" to scope, "revision" to 2L,
            "enabled" to true, "sound" to true, "vibration" to true,
            "dnd" to true, "start" to start, "end" to end, "rooms" to mapOf(room to false))))
        receive()
        assertEquals("chatflow_silent", notifications().single().notification.channelId)
        assertTrue(owner.install(mapOf("scope" to scope, "revision" to 3L,
            "enabled" to true, "sound" to true, "vibration" to true,
            "dnd" to true, "start" to 5, "end" to 5, "rooms" to mapOf(room to false))))
        receive("d".repeat(64))
        assertEquals("chatflow_messages_v2", notifications().single().notification.channelId)
    }
    @Test fun stalePendingAndFutureClaimsArePrunedAndClaimBudgetDoesNotEvictToAudible() {
        val db = app.openOrCreateDatabase("native_messages.db",0,null)
        db.use {
            it.execSQL("INSERT INTO claims VALUES(?,?,?,0)", arrayOf<Any>(event,room,System.currentTimeMillis()-301_000))
            owner.retryPending()
            assertTrue(notifications().isEmpty())
            it.execSQL("INSERT INTO claims VALUES(?,?,?,3)", arrayOf<Any>(event,room,System.currentTimeMillis()+90_000))
            receive()
            assertEquals(1, notifications().size)
            it.execSQL("DELETE FROM claims")
            it.beginTransaction()
            try {
                repeat(4096) { n -> it.execSQL("INSERT INTO claims VALUES(?,?,?,2)",
                    arrayOf<Any>(n.toString(16).padStart(64,'0'),room,System.currentTimeMillis())) }
                it.setTransactionSuccessful()
            } finally { it.endTransaction() }
            assertFalse(owner.claim(scope,room,"f".repeat(64)))
            assertEquals(4096, it.rawQuery("SELECT COUNT(*) FROM claims",null).use { c -> c.moveToFirst(); c.getInt(0) })
        }
    }
    @Test fun failedDurablePolicyWriteStaysQuietAcrossRestartAndCanRecover() {
        app.openOrCreateDatabase("native_messages.db",0,null).use { db ->
            db.execSQL("CREATE TRIGGER fail_policy BEFORE UPDATE OF policy ON state BEGIN SELECT RAISE(ABORT, 'fixture'); END")
            val snapshot = mapOf("scope" to scope, "revision" to 2L,
                "enabled" to true, "sound" to false, "vibration" to false,
                "dnd" to false, "start" to 0, "end" to 0, "rooms" to mapOf(room to true))
            assertFails { owner.install(snapshot) }
            receive()
            assertTrue(notifications().isEmpty())
            owner.close(); owner = NativeMessageOwner(app)
            receive()
            assertTrue(notifications().isEmpty())
            db.execSQL("DROP TRIGGER fail_policy")
            assertTrue(owner.install(snapshot))
            receive()
            assertEquals("chatflow_silent", notifications().single().notification.channelId)
        }
    }
    @Test fun pendingWakeAndDisplayedNotificationAndTapBudgetsAreBounded() {
        owner.foreground = true
        repeat(40) { n -> owner.receive(scope,room,n.toString(16).padStart(64,'0')) }
        app.openOrCreateDatabase("native_messages.db",0,null).use { db ->
            assertEquals(32, db.rawQuery("SELECT COUNT(*) FROM claims WHERE status=0",null).use { it.moveToFirst(); it.getInt(0) })
            db.execSQL("DELETE FROM claims")
            owner.foreground = false
            repeat(40) { n ->
                val key = n.toString(16).padStart(8,'0') + "a".repeat(56)
                owner.receive(scope,key,key)
                assertTrue(owner.tap(scope,key,key))
            }
            assertEquals(32, notifications().size)
            assertEquals(1, db.rawQuery("SELECT COUNT(*) FROM tap",null).use { it.moveToFirst(); it.getInt(0) })
            db.execSQL("UPDATE tap SET at=?", arrayOf(System.currentTimeMillis()-301_000))
            assertNull(owner.takeTap())
        }
    }
    @Test fun newAccountStartsItsOwnRevisionAfterHighRevisionRevocation() {
        val oldScope = scope
        owner.invalidate(scope, 40)
        owner.revoke()
        scope = owner.bind("d".repeat(64))
        val snapshot = mapOf("scope" to scope, "revision" to 1L,
            "enabled" to true, "sound" to true, "vibration" to true,
            "dnd" to false, "start" to 0, "end" to 0, "rooms" to mapOf(room to false))
        assertTrue(owner.install(snapshot))
        assertFalse(owner.install(snapshot + ("scope" to oldScope) + ("revision" to 100L)))
        receive()
        assertEquals(1, notifications().size)
    }
    @Test fun expiredForegroundClaimCannotPresentAfterNativeTakeover() {
        owner.foreground = true
        assertTrue(owner.claim(scope,room,event))
        app.openOrCreateDatabase("native_messages.db",0,null).use {
            it.execSQL("UPDATE claims SET at=?",arrayOf(System.currentTimeMillis()-6000))
        }
        owner.foreground = false
        owner.retryPending()
        assertEquals(1, notifications().size)
        owner.foreground = true
        assertFalse(owner.beginForeground(scope,event))
    }
    @Test fun activeForegroundPresentationKeepsOwnershipAndAbandonmentRestoresFallback() {
        owner.foreground = true
        assertTrue(owner.claim(scope,room,event))
        assertTrue(owner.beginForeground(scope,event))
        app.openOrCreateDatabase("native_messages.db",0,null).use {
            it.execSQL("UPDATE claims SET at=?",arrayOf(System.currentTimeMillis()-6000))
        }
        owner.foreground = false
        owner.retryPending()
        assertTrue(notifications().isEmpty())
        owner.finishForeground(scope,event,false)
        assertEquals(1, notifications().size)
        owner.finishForeground(scope,event,true)
        owner.retryPending()
        assertEquals(1, notifications().size)
    }
}
