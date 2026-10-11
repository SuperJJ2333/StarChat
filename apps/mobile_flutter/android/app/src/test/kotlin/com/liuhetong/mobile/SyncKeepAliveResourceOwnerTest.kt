package com.liuhetong.mobile

import android.app.Application
import android.content.pm.ServiceInfo
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import com.dexterous.flutterlocalnotifications.ForegroundService
import com.liuhetong.mobile.call.CallForegroundService
import com.liuhetong.mobile.call.CallManager
import org.robolectric.shadows.ShadowPowerManager
import org.junit.After
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.RuntimeEnvironment
import android.os.Looper
import java.time.Duration
import kotlin.test.assertTrue
import kotlin.test.assertFalse
import kotlin.test.assertEquals

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class, manifest = Config.NONE)
class SyncKeepAliveResourceOwnerTest {
    @After
    fun detachOwner() { ForegroundService.setResourceOwner(null) }

    @Test
    fun wifiFailureReturnsFalseAndRollsBackCpuLock() {
        val context = object : ContextWrapper(RuntimeEnvironment.getApplication()) {
            override fun getApplicationContext(): Context = this
            override fun getSystemService(name: String): Any? {
                if (name == Context.WIFI_SERVICE) throw SecurityException("fixture")
                return super.getSystemService(name)
            }
        }
        val owner = SyncKeepAliveResourceOwner(context)
        owner.onStarted()
        assertFalse(owner.acquire())
        assertFalse(owner.locksHeld)
        assertFalse(ShadowPowerManager.getLatestWakeLock().isHeld)
    }

    @Test
    fun timeoutReleasesLocksStopsSelfThenSignalsAndLeavesNativeCallAlone() {
        val context = RuntimeEnvironment.getApplication()
        val owner = SyncKeepAliveResourceOwner(context)
        ForegroundService.setResourceOwner(owner)
        val service = Robolectric.buildService(ForegroundService::class.java).create().get()
        owner.onStarted()
        assertTrue(owner.acquire())
        CallManager.reset()
        CallManager.onIncoming("synthetic-call", "Test", false)
        val call = Robolectric.buildService(CallForegroundService::class.java).create().get()
        call.onStartCommand(Intent(context, CallForegroundService::class.java), 0, 1)
        assertFalse(shadowOf(call).isStoppedBySelf)
        var signals = 0
        owner.onEvent = {
            assertFalse(owner.locksHeld)
            assertTrue(shadowOf(service).isStoppedBySelf)
            assertFalse(shadowOf(call).isStoppedBySelf)
            signals++
        }
        service.onTimeout(1, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        service.onTimeout(1, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        service.onDestroy()
        assertEquals(1, signals)
        assertFalse(owner.serviceRunning)
        assertEquals(CallManager.State.ringing, CallManager.state)
        call.onDestroy()
        CallManager.reset()
    }

    @Test
    fun locksRequireConfirmedServiceAndExpireTogetherWithoutDart() {
        val owner = SyncKeepAliveResourceOwner(RuntimeEnvironment.getApplication())
        assertFalse(owner.acquire())
        owner.onStarted()
        assertTrue(owner.acquire())
        assertTrue(owner.locksHeld)
        owner.setForeground(false)
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMinutes(20))
        assertFalse(owner.locksHeld)
        assertTrue(owner.serviceRunning)
        assertFalse(owner.acquire(), "background must not renew an expired lease")
        owner.setForeground(true)
        assertTrue(owner.acquire())
        owner.release()
        owner.release()
        assertFalse(owner.locksHeld)
    }

    @Test
    fun stoppedBlocksBackgroundRestartUntilLegalForeground() {
        val owner = SyncKeepAliveResourceOwner(RuntimeEnvironment.getApplication())
        owner.onStarted()
        assertTrue(owner.acquire())
        owner.release()
        owner.onStopped("timeout")
        assertFalse(owner.locksHeld)
        assertFalse(owner.serviceRunning)
        assertFalse(owner.canStart())
        owner.setForeground(true)
        assertTrue(owner.canStart())
    }

    @Test
    fun callStartingAfterTimeoutDoesNotReenableSyncLocksInBackground() {
        val owner = SyncKeepAliveResourceOwner(RuntimeEnvironment.getApplication())
        owner.onStopped("timeout")
        owner.onStarted() // A legitimate microphone/camera request can start independently.
        assertTrue(owner.serviceRunning)
        assertFalse(owner.acquire())
        assertFalse(owner.canStart())
        owner.setForeground(true)
        owner.onStarted()
        assertTrue(owner.acquire())
        owner.release()
    }

    @Test
    fun leaseExpiryPublishesOnlyAfterBothLocksWereReleased() {
        val owner = SyncKeepAliveResourceOwner(RuntimeEnvironment.getApplication())
        owner.onStarted()
        assertTrue(owner.acquire())
        val events = mutableListOf<String>()
        owner.onEvent = { event ->
            assertFalse(owner.locksHeld)
            events.add(event)
        }
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMinutes(20))
        assertEquals(listOf("locksReleased"), events)
    }

    @Test
    fun timeoutStopsServiceWithoutWaitingForDart() {
        val service = Robolectric.buildService(ForegroundService::class.java).create().get()
        service.onTimeout(1, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        assertTrue(shadowOf(service).isStoppedBySelf)
    }

    @Test
    fun destroyAlsoClosesTheServiceAndRepeatedTimeoutIsSafe() {
        val service = Robolectric.buildService(ForegroundService::class.java).create().get()
        service.onTimeout(1, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        service.onTimeout(1, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        service.onDestroy()
        assertTrue(shadowOf(service).isStoppedBySelf)
    }
}
