package com.liuhetong.mobile

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import com.dexterous.flutterlocalnotifications.ForegroundService

/** Application-scoped sync locks. The service, never Dart, owns final cleanup. */
class SyncKeepAliveResourceOwner(context: Context) : ForegroundService.ResourceOwner {
    private val app = context.applicationContext
    private val handler = Handler(Looper.getMainLooper())
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var foreground = false
    private var restartBlocked = false
    private var leaseExpired = false
    var onEvent: ((String) -> Unit)? = null
    var serviceRunning = false
        private set
    val locksHeld: Boolean
        get() = wakeLock?.isHeld == true && wifiLock?.isHeld == true

    private val expire = Runnable {
        release()
        leaseExpired = true
        emit("locksReleased")
    }

    override fun canStart(): Boolean = !restartBlocked || foreground

    override fun onStarted() {
        serviceRunning = true
        // A call may be allowed by Android while sync remains blocked. Only a
        // foreground recovery may clear the previous sync timeout/stop gate.
        restartBlocked = restartBlocked && !foreground
    }

    fun setForeground(value: Boolean) { foreground = value }

    fun acquire(): Boolean {
        if (!serviceRunning || restartBlocked || (leaseExpired && !foreground)) return false
        if (locksHeld) return true
        release()
        return try {
            val pm = app.getSystemService(PowerManager::class.java)
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "chatflow:sync").apply {
                setReferenceCounted(false)
                acquire(LEASE_MILLIS)
            }
            val wifi = app.getSystemService(WifiManager::class.java)
            val mode = if (Build.VERSION.SDK_INT >= 34) WifiManager.WIFI_MODE_FULL_LOW_LATENCY
                else WifiManager.WIFI_MODE_FULL_HIGH_PERF
            wifiLock = wifi.createWifiLock(mode, "chatflow:sync").apply {
                setReferenceCounted(false)
                acquire()
            }
            leaseExpired = false
            handler.postDelayed(expire, LEASE_MILLIS)
            locksHeld
        } catch (_: Exception) {
            release() // A Wi-Fi failure must also return the already acquired CPU lock.
            false
        }
    }

    override fun release() {
        handler.removeCallbacks(expire)
        try { wakeLock?.takeIf { it.isHeld }?.release() } catch (_: Exception) {}
        try { wifiLock?.takeIf { it.isHeld }?.release() } catch (_: Exception) {}
        wakeLock = null
        wifiLock = null
    }

    override fun onStopped(reason: String) {
        serviceRunning = false
        restartBlocked = true
        emit("stopped")
    }

    private fun emit(event: String) {
        try { onEvent?.invoke(event) } catch (_: Exception) {}
    }

    companion object {
        private const val LEASE_MILLIS = 20 * 60 * 1000L
        private var instance: SyncKeepAliveResourceOwner? = null
        fun get(context: Context): SyncKeepAliveResourceOwner =
            instance ?: SyncKeepAliveResourceOwner(context).also { instance = it }
    }
}
