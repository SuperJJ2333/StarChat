package com.liuhetong.mobile.update

import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.io.File
import java.nio.file.Files
import java.security.KeyPairGenerator
import java.security.Signature
import java.util.zip.DeflaterOutputStream
import kotlin.test.*

class DeltaApplierTest {
    @Test fun `background cancels preparation checkpoint and resume requires explicit retry`() {
        val clock = java.util.concurrent.atomic.AtomicLong(0)
        val gate = DeltaWorkGate { clock.get() }
        gate.pause(true)
        val completed = java.util.concurrent.CountDownLatch(1)
        val interrupted = java.util.concurrent.atomic.AtomicBoolean(false)
        val worker = Thread {
            try { gate.checkpoint() } catch (_: InterruptedException) { interrupted.set(true) }
            finally { completed.countDown() }
        }.apply { start() }
        try {
            gate.foreground(false)
            assertTrue(completed.await(1, java.util.concurrent.TimeUnit.SECONDS), "Background must terminate rather than indefinitely hold shared lease")
            assertTrue(interrupted.get())
            assertTrue(gate.isCancelled)
            // onPause may arrive before a queued MethodChannel prepare/restart.
            gate.restart()
            assertTrue(gate.isCancelled, "New preparation in background must remain cancelled")
            assertFailsWith<InterruptedException> { gate.checkpoint() }
            gate.foreground(true)
            assertTrue(gate.isCancelled, "Resume must not silently restart preparation/install")
            gate.restart(); gate.pause(false); clock.set(1000); gate.pause(false); gate.checkpoint()
        } finally { gate.close(); worker.join(1000) }
    }
    @Test fun `worker gate pauses chunks waits quiet interval and cancels promptly`() {
        var clock = 0L
        val gate = DeltaWorkGate { clock }
        gate.pause(true)
        val entered = java.util.concurrent.CountDownLatch(1)
        val finished = java.util.concurrent.CountDownLatch(1)
        val thread = Thread { entered.countDown(); gate.checkpoint(); finished.countDown() }.apply { start() }
        assertTrue(entered.await(1, java.util.concurrent.TimeUnit.SECONDS))
        assertFalse(finished.await(50, java.util.concurrent.TimeUnit.MILLISECONDS))
        gate.pause(false)
        assertFalse(finished.await(50, java.util.concurrent.TimeUnit.MILLISECONDS))
        clock = 501L; gate.pause(false)
        assertTrue(finished.await(1, java.util.concurrent.TimeUnit.SECONDS)); thread.join()
        gate.cancel(); assertFailsWith<InterruptedException> { gate.checkpoint() }
        gate.restart(); gate.checkpoint()
        gate.foreground(false)
        val cancelled = java.util.concurrent.CountDownLatch(1)
        val second = Thread { try { gate.checkpoint() } catch (_: InterruptedException) { cancelled.countDown() } }.apply { start() }
        gate.close(); assertTrue(cancelled.await(1, java.util.concurrent.TimeUnit.SECONDS)); second.join()
    }
    private val artifactDir: File get() = File(generateSequence(File(System.getProperty("user.dir"))) { it.parentFile }
        .first { File(it, "scripts/build_android_delta.py").isFile }, "docs/verification/artifacts/2026-10-09/mobile-responsive-maintenance/delta").apply { mkdirs() }
    @Test fun `trusted output bound must match compressed header before applying`() {
        val base = "hello".toByteArray()
        val file = File(artifactDir, "bound-test.delta").apply { writeBytes(patch(base, base, 1) { writeByte(0); writeLong(0); writeLong(5) }) }
        try {
            assertFails { DeltaApplier.verifyHeader(file, 5, 4, DeltaApplier.hex(DeltaApplier.sha256(base)), DeltaApplier.hex(DeltaApplier.sha256(base))) }
            DeltaApplier.verifyHeader(file, 5, 5, DeltaApplier.hex(DeltaApplier.sha256(base)), DeltaApplier.hex(DeltaApplier.sha256(base)))
        } finally { file.delete() }
    }
    @Test fun `real signed APK protocol interoperability when explicit fixtures supplied`() {
        val base = System.getenv("ANDROID_DELTA_TEST_BASE")
        val patch = System.getenv("ANDROID_DELTA_TEST_PATCH")
        val target = System.getenv("ANDROID_DELTA_TEST_TARGET")
        org.junit.Assume.assumeTrue(base != null && patch != null && target != null)
        val output = File(patch!!).resolveSibling("native-reconstructed.apk")
        try {
            // Reflection keeps JVM-only allocation counters out of Android's boot classpath.
            val allocations = Class.forName("java.lang.management.ManagementFactory").getMethod("getThreadMXBean").invoke(null)
            val counter = Class.forName("com.sun.management.ThreadMXBean").getMethod("getThreadAllocatedBytes", java.lang.Long.TYPE)
            val startAllocated = counter.invoke(allocations, Thread.currentThread().id) as Long
            DeltaApplier.apply(File(base!!), File(patch), output)
            val allocated = (counter.invoke(allocations, Thread.currentThread().id) as Long) - startAllocated
            println("native_applier_total_allocated_bytes=$allocated")
            assertTrue(allocated in 1..(8L * 1024 * 1024), "Entire JVM reconstruction allocation must fit working budget")
            assertEquals(DeltaApplier.hash(File(target!!)), DeltaApplier.hash(output))
            assertEquals(File(target).length(), output.length())
        } finally { output.delete() }
    }
    private fun patch(base: ByteArray, target: ByteArray, count: Int = 2, commands: DataOutputStream.() -> Unit): ByteArray {
        val result = ByteArrayOutputStream()
        DataOutputStream(result).apply {
            writeBytes("CFDELTA1"); writeLong(base.size.toLong()); writeLong(target.size.toLong())
            write(DeltaApplier.sha256(base)); write(DeltaApplier.sha256(target)); writeInt(count); flush()
        }
        DataOutputStream(DeflaterOutputStream(result)).use { it.commands() }
        return result.toByteArray()
    }
    private fun run(data: ByteArray, base: ByteArray = "hello".toByteArray(), checkpoint: () -> Unit = {}): File {
        val dir = Files.createTempDirectory(artifactDir.toPath(), "delta-test").toFile()
        val old = File(dir, "base").apply { writeBytes(base) }
        val patch = File(dir, "patch").apply { writeBytes(data) }
        val out = File(dir, "target")
        try { DeltaApplier.apply(old, patch, out, checkpoint); return out }
        catch (e: Exception) { assertFalse(out.exists()); dir.deleteRecursively(); throw e }
    }
    @Test fun `streaming copy and add reconstruct exact bytes`() {
        val base = "hello".toByteArray(); val target = "hello world".toByteArray()
        val data = patch(base, target) { writeByte(0); writeLong(0); writeLong(5); writeByte(1); writeLong(6); writeBytes(" world") }
        val out = run(data); assertContentEquals(target, out.readBytes()); out.parentFile.deleteRecursively()
    }
    @Test fun `wrong baseline truncation overflow unknown operation and trailing data fail closed`() {
        val base = "hello".toByteArray()
        val data = patch(base, base, 1) { writeByte(0); writeLong(0); writeLong(5) }
        assertFails { run(data, "wrong".toByteArray()) }
        assertFails { run(data.copyOf(data.size - 2)) }
        assertFails { run(data + byteArrayOf(1)) }
        assertFails { run(patch(base, base, 1) { writeByte(0); writeLong(Long.MAX_VALUE); writeLong(5) }) }
        assertFails { run(patch(base, base, 1) { writeByte(1); writeLong(Long.MAX_VALUE) }) }
        assertFails { run(patch(base, base, 1) { writeByte(8) }) }
        assertFails { run(patch(base, base, 100001) {}) }
        assertFails { run(patch(base, base, 1) { writeByte(1); writeLong(5); writeBytes("wrong") }) }
    }
    @Test fun `cancel leaves no installable target`() {
        val base = "hello".toByteArray()
        val data = patch(base, base, 1) { writeByte(0); writeLong(0); writeLong(5) }
        assertFails { run(data, checkpoint = { throw InterruptedException() }) }
    }
    @Test fun `manifest signature is rooted in installed key not supplied key`() {
        val trusted = KeyPairGenerator.getInstance("RSA").apply { initialize(2048) }.generateKeyPair()
        val attacker = KeyPairGenerator.getInstance("RSA").apply { initialize(2048) }.generateKeyPair()
        val bytes = "release metadata".toByteArray()
        fun sign(key: java.security.PrivateKey) = Signature.getInstance("SHA256withRSA").run { initSign(key); update(bytes); sign() }
        assertTrue(DeltaTrust.verify(bytes, sign(trusted.private), trusted.public))
        assertFalse(DeltaTrust.verify(bytes, sign(attacker.private), trusted.public))
        assertFalse(DeltaTrust.verify(bytes + byteArrayOf(1), sign(trusted.private), trusted.public))
    }
    @Test fun `disk and install identity and permission gates`() {
        assertFalse(DeltaPolicy.enoughSpace(100, 20, 100))
        assertTrue(DeltaPolicy.enoughSpace(100000000, 20, 100))
        assertFalse(DeltaPolicy.validTarget("a", 4, setOf("one"), "b", 4, setOf("one"), 3))
        assertFalse(DeltaPolicy.validTarget("a", 4, setOf("one"), "a", 4, setOf("two"), 3))
        assertFalse(DeltaPolicy.validTarget("a", 4, setOf("one"), "a", 4, setOf("one"), 4))
        assertTrue(DeltaPolicy.validTarget("a", 4, setOf("one"), "a", 4, setOf("one"), 3))
        assertEquals("permission_required", DeltaPolicy.installAction(28, false))
        assertEquals("install", DeltaPolicy.installAction(28, true))
    }
}
