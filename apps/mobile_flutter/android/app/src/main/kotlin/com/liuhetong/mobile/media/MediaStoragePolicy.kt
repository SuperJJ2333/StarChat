package com.liuhetong.mobile.media

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.NoSuchFileException
import java.nio.file.attribute.BasicFileAttributes

/** Fixed app-private roots only. No arbitrary path is accepted from Dart. */
class MediaStoragePolicy(private val context: Context) {
    private val hex = Regex("^[0-9a-f]{64}$")

    private fun attributes(file: File): BasicFileAttributes? = try {
        Files.readAttributes(file.toPath(), BasicFileAttributes::class.java, LinkOption.NOFOLLOW_LINKS)
    } catch (_: NoSuchFileException) {
        null
    }

    private fun root(): File {
        check(!context.isDeviceProtectedStorage) { "Credential storage required" }
        val parent = context.noBackupFilesDir.canonicalFile
        val directory = File(parent, "pending-media-v1")
        check(attributes(directory)?.isSymbolicLink != true) { "Invalid directory" }
        check(directory.canonicalFile == directory.absoluteFile) { "Invalid directory" }
        check(directory.isDirectory || directory.mkdirs()) { "Directory unavailable" }
        check(directory.canRead() && directory.canWrite()) { "Directory unavailable" }
        return directory
    }

    fun pendingDirectory(): Map<String, Any> {
        val directory = root()
        return mapOf("path" to directory.path,
            "availableBytes" to directory.usableSpace.coerceAtLeast(0L),
            "protected" to true, "backupExcluded" to true)
    }

    private fun checked(file: File, root: File, directory: Boolean = false): File {
        val entry = attributes(file)
        check(file.canonicalFile == file.absoluteFile &&
            file.path.startsWith(root.path + File.separator)) { "Invalid storage entry" }
        check(entry != null && !entry.isSymbolicLink &&
            (if (directory) entry.isDirectory else entry.isRegularFile)) { "Storage entry unavailable" }
        return file
    }

    fun sealPendingFiles(scope: String, sourceId: String?): Map<String, Any> {
        require(hex.matches(scope) && (sourceId == null || hex.matches(sourceId)))
        val root = root()
        val namespace = checked(File(root, scope), root, directory = true)
        checked(File(namespace, "manifest-v1.db"), root)
        for (suffix in listOf("-journal", "-wal", "-shm")) {
            val file = File(namespace, "manifest-v1.db$suffix")
            if (attributes(file) != null) checked(file, root)
        }
        if (sourceId != null) {
            val sources = checked(File(namespace, "sources"), root, directory = true)
            var found = false
            for (suffix in listOf(".bin", ".bin.part")) {
                val file = File(sources, sourceId + suffix)
                if (attributes(file) != null) {
                    checked(file, root)
                    found = true
                }
            }
            check(found) { "Source unavailable" }
        }
        // noBackupFilesDir is excluded from both automatic and D2D backups by
        // the platform. Children remain in the app's credential-encrypted UID
        // sandbox; no external/shared storage or Android global backup change.
        return mapOf("protected" to true, "backupExcluded" to true)
    }

    companion object {
        fun attach(context: Context, messenger: BinaryMessenger) {
            val policy = MediaStoragePolicy(context)
            MethodChannel(messenger, "chatflow/media_storage", StandardMethodCodec.INSTANCE,
                messenger.makeBackgroundTaskQueue()).setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "pendingMediaDirectory" -> {
                            require(call.arguments == null)
                            result.success(policy.pendingDirectory())
                        }
                        "sealPendingFiles" -> {
                            val args = call.arguments as? Map<*, *> ?: error("Invalid arguments")
                            require(args.keys.all { it == "scope" || it == "sourceId" })
                            val scope = args["scope"] as? String ?: error("Invalid scope")
                            val source = args["sourceId"]
                            require(source == null || source is String)
                            result.success(policy.sealPendingFiles(scope, source as String?))
                        }
                        else -> result.notImplemented()
                    }
                } catch (_: Exception) {
                    result.error("MEDIA_STORAGE_UNAVAILABLE", "Protected media storage unavailable", null)
                }
            }
        }
    }
}
