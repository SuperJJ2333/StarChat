package com.liuhetong.mobile.media

import android.app.Application
import android.content.ContextWrapper
import java.io.File
import java.util.UUID
import kotlin.test.assertEquals
import kotlin.test.assertFails
import kotlin.test.assertTrue
import org.junit.After
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class, manifest = Config.NONE)
class MediaStoragePolicyTest {
    private val repository = generateSequence(File(System.getProperty("user.dir"))) { it.parentFile }
        .first { File(it, "docs/verification").isDirectory }
    private val fixture = File(repository,
        "docs/verification/artifacts/2026-10-11/im-reliability-implementation/native-storage/${UUID.randomUUID()}")
    private fun context(deviceProtected: Boolean = false) = object : ContextWrapper(RuntimeEnvironment.getApplication()) {
        override fun getNoBackupFilesDir(): File = File(fixture, "no_backup").apply { mkdirs() }
        override fun isDeviceProtectedStorage(): Boolean = deviceProtected
    }
    @After fun clean() {
        check(fixture.canonicalPath.startsWith(File(repository, "docs/verification/artifacts").canonicalPath + File.separator))
        fixture.deleteRecursively()
    }
    @Test fun pendingUsesCredentialProtectedNoBackupRoot() {
        val result = MediaStoragePolicy(context()).pendingDirectory()
        assertEquals(File(fixture, "no_backup/pending-media-v1").canonicalPath, result["path"])
        assertEquals(true, result["protected"])
        assertEquals(true, result["backupExcluded"])
        assertTrue((result["availableBytes"] as Long) >= 0)
    }
    @Test fun refusesDeviceProtectedContext() {
        assertFails { MediaStoragePolicy(context(true)).pendingDirectory() }
    }
    @Test fun refusesTraversalAndMissingSourceWithoutDeletingOriginal() {
        val policy = MediaStoragePolicy(context())
        for (value in listOf("../outside", "", "g".repeat(64), "a".repeat(63))) {
            assertFails { policy.sealPendingFiles(value, null) }
        }
        val scope = "a".repeat(64)
        assertFails { policy.sealPendingFiles(scope, null) }
        val root = File(policy.pendingDirectory()["path"] as String, scope).apply { mkdirs() }
        File(root, "manifest-v1.db").writeText("synthetic")
        assertFails { policy.sealPendingFiles(scope, "b".repeat(64)) }
        assertEquals("synthetic", File(root, "manifest-v1.db").readText())
    }
    @Test fun sealsOnlyFixedManifestAndSourceNames() {
        val policy = MediaStoragePolicy(context())
        val scope = "c".repeat(64)
        val source = "d".repeat(64)
        val root = File(policy.pendingDirectory()["path"] as String, scope).apply { mkdirs() }
        File(root, "manifest-v1.db").writeText("synthetic")
        File(root, "manifest-v1.db-wal").writeText("synthetic-wal")
        val sources = File(root, "sources").apply { mkdirs() }
        File(sources, "$source.bin.part").writeText("synthetic-source")
        assertEquals(true, policy.sealPendingFiles(scope, source)["protected"])
        assertEquals("synthetic-source", File(sources, "$source.bin.part").readText())
        assertEquals(true, policy.sealPendingFiles(scope, source)["backupExcluded"])
    }
}
