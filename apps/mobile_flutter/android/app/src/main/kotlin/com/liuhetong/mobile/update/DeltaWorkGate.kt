package com.liuhetong.mobile.update

/** Cooperative checkpoints outside file IO; monotonic 500ms foreground quiet time. */
class DeltaWorkGate(private val clock: () -> Long = { System.nanoTime() / 1000000 }) {
    private val monitor = Object()
    private var paused = false
    private var background = false
    private var quietUntil = clock() + 500
    private var cancelled = false
    private var closed = false
    val isCancelled: Boolean get() = synchronized(monitor) { cancelled || closed }
    fun pause(value: Boolean) = synchronized(monitor) {
        if (paused && !value) quietUntil = clock() + 500
        paused = value; monitor.notifyAll()
    }
    fun foreground(value: Boolean) = synchronized(monitor) {
        background = !value
        // APK preparation never owns the shared heavy lease while suspended in
        // background. Its finally releases ownership; validated patch files stay.
        if (!value) cancelled = true
        quietUntil = clock() + 500; monitor.notifyAll()
    }
    fun cancel() = synchronized(monitor) { cancelled = true; monitor.notifyAll() }
    fun restart() = synchronized(monitor) { check(!closed); cancelled = background }
    fun close() = synchronized(monitor) { closed = true; cancelled = true; monitor.notifyAll() }
    fun checkpoint() = synchronized(monitor) {
        while ((paused || background || clock() < quietUntil) && !cancelled && !closed) monitor.wait(250)
        if (cancelled || closed || Thread.currentThread().isInterrupted) throw InterruptedException()
    }
}
