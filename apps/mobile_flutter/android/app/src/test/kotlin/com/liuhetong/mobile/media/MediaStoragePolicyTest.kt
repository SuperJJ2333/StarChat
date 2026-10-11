package com.liuhetong.mobile.media

import android.app.Application
import android.content.ContextWrapper
import android.system.ErrnoException
import android.system.OsConstants
import android.system.StructStat
import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.NoSuchFileException
import java.nio.file.attribute.BasicFileAttributes
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
import org.robolectric.annotation.Implementation
import org.robolectric.annotation.Implements
import org.robolectric.shadows.ShadowLinux

// Robolectric 4.14.1 delegates lstat to stat and reports mode=0 instead of
// ENOENT for a missing file. Model the real no-follow OS contract using the
// host filesystem; device integration remains a separate acceptance gate.
@Implements(className = "libcore.io.Linux", isInAndroidSdk = false, minSdk = 26)
class NoFollowLinux : ShadowLinux() {
    @Implementation
    override fun lstat(path: String): StructStat = inspectNoFollow(path)
}

fun inspectNoFollow(path: String): StructStat {
        val entry = try {
            Files.readAttributes(File(path).toPath(), BasicFileAttributes::class.java,
                LinkOption.NOFOLLOW_LINKS)
        } catch (_: NoSuchFileException) {
            throw ErrnoException("lstat", OsConstants.ENOENT)
        }
        val mode = when {
            entry.isSymbolicLink -> OsConstants.S_IFLNK
            entry.isDirectory -> OsConstants.S_IFDIR
            entry.isRegularFile -> OsConstants.S_IFREG
            else -> 0
        }
        return StructStat(0L, 0L, mode, 0L, 0, 0, 0L, entry.size(), 0L, 0L, 0L, 0L, 0L)
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [24, 35], application = Application::class, manifest = Config.NONE,
    shadows = [NoFollowLinux::class, NoFollowPosix::class])
class MediaStoragePolicyTest {
    private val repository = generateSequence(File(requireNotNull(System.getProperty("user.dir")))) { it.parentFile }
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

    @Test fun rejectsDirectoryInManifestOrSourcePosition() {
        val policy = MediaStoragePolicy(context())
        val scope = "e".repeat(64)
        val source = "f".repeat(64)
        val root = File(policy.pendingDirectory()["path"] as String, scope).apply { mkdirs() }
        val manifest = File(root, "manifest-v1.db").apply { mkdirs() }
        assertFails { policy.sealPendingFiles(scope, null) }
        check(manifest.delete())
        manifest.writeText("synthetic")
        File(root, "sources/$source.bin").mkdirs()
        assertFails { policy.sealPendingFiles(scope, source) }
    }

    @Test fun rejectsDanglingOptionalJournalAndPart() {
        val policy = MediaStoragePolicy(context())
        val scope = "e".repeat(64)
        val source = "f".repeat(64)
        val root = File(policy.pendingDirectory()["path"] as String, scope).apply { mkdirs() }
        File(root, "manifest-v1.db").writeText("synthetic")
        val sources = File(root, "sources").apply { mkdirs() }
        File(sources, "$source.bin").writeText("synthetic-source")
        val wal = File(root, "manifest-v1.db-wal").toPath()
        Files.createSymbolicLink(wal, File(root, "absent-wal").toPath())
        assertFails { policy.sealPendingFiles(scope, source) }
        Files.delete(wal)
        Files.createSymbolicLink(File(sources, "$source.bin.part").toPath(),
            File(sources, "absent-part").toPath())
        assertFails { policy.sealPendingFiles(scope, source) }
        assertEquals("synthetic-source", File(sources, "$source.bin").readText())
    }
}
