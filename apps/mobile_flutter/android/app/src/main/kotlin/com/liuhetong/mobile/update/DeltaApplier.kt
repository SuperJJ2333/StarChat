package com.liuhetong.mobile.update

import java.io.*
import java.security.MessageDigest
import java.util.zip.Inflater
import java.util.zip.InflaterInputStream

/** All work buffers are 64KiB; neither input APK nor literals are materialized. */
object DeltaApplier {
    const val BUFFER = 65536
    const val MAX_SIZE = 512L * 1024 * 1024
    const val MAX_OPERATIONS = 100000
    fun sha256(bytes: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(bytes)
    fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it.toInt() and 255) }
    fun hash(file: File, checkpoint: () -> Unit = {}): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(BUFFER)
            while (true) { checkpoint(); val n = input.read(buffer); if (n < 0) break; digest.update(buffer, 0, n) }
        }
        return hex(digest.digest())
    }
    private class StrictZlib(input: InputStream) : InflaterInputStream(input, Inflater(), BUFFER) {
        fun finishExactly() {
            require(read() == -1) { "extra operations" }
            require(inf.finished() && inf.remaining == 0 && `in`.read() == -1) { "trailing or truncated zlib" }
        }
    }
    fun verifyHeader(patch: File, baseSize: Long, targetSize: Long, baseHash: String, targetHash: String) {
        DataInputStream(patch.inputStream()).use { input ->
            val magic = ByteArray(8).also { input.readFully(it) }
            require(String(magic, Charsets.US_ASCII) == "CFDELTA1")
            require(input.readLong() == baseSize && input.readLong() == targetSize) { "manifest/header size mismatch" }
            require(hex(ByteArray(32).also { input.readFully(it) }) == baseHash)
            require(hex(ByteArray(32).also { input.readFully(it) }) == targetHash)
            require(input.readInt() in 1..MAX_OPERATIONS)
        }
    }
    fun apply(base: File, patch: File, output: File, checkpoint: () -> Unit = {}) {
        require(output.canonicalFile != base.canonicalFile && output.canonicalFile != patch.canonicalFile)
        val part = File(output.parentFile, output.name + ".part")
        try {
            DataInputStream(BufferedInputStream(patch.inputStream(), BUFFER)).use { header ->
                val magic = ByteArray(8).also { header.readFully(it) }
                val oldSize = header.readLong(); val newSize = header.readLong()
                val oldHash = ByteArray(32).also { header.readFully(it) }
                val newHash = ByteArray(32).also { header.readFully(it) }
                val count = header.readInt()
                require(String(magic, Charsets.US_ASCII) == "CFDELTA1")
                require(oldSize in 1..MAX_SIZE && newSize in 1..MAX_SIZE && count in 1..MAX_OPERATIONS)
                require(base.length() == oldSize && hash(base, checkpoint) == hex(oldHash)) { "wrong base" }
                val zlib = StrictZlib(header)
                try {
                val commands = DataInputStream(zlib)
                val digest = MessageDigest.getInstance("SHA-256")
                val buffer = ByteArray(BUFFER)
                var written = 0L
                RandomAccessFile(base, "r").use { old ->
                    FileOutputStream(part).use { out ->
                        repeat(count) {
                            checkpoint()
                            val kind = commands.readUnsignedByte()
                            val length: Long
                            when (kind) {
                                0 -> {
                                    val offset = commands.readLong(); length = commands.readLong()
                                    require(offset >= 0 && offset <= oldSize && length > 0 && length <= oldSize - offset) { "copy bounds" }
                                    old.seek(offset)
                                }
                                1 -> length = commands.readLong()
                                else -> throw IOException("unsupported operation")
                            }
                            require(length > 0 && length <= newSize - written) { "output bounds" }
                            var remaining = length
                            while (remaining > 0) {
                                checkpoint()
                                val n = minOf(BUFFER.toLong(), remaining).toInt()
                                if (kind == 0) old.readFully(buffer, 0, n) else commands.readFully(buffer, 0, n)
                                out.write(buffer, 0, n); digest.update(buffer, 0, n)
                                remaining -= n
                            }
                            written += length
                        }
                        zlib.finishExactly()
                        require(written == newSize && digest.digest().contentEquals(newHash)) { "target hash/size" }
                        out.fd.sync()
                    }
                }
                } finally { zlib.close() }
            }
            checkpoint()
            require(part.renameTo(output)) { "atomic rename failed" }
        } finally { part.delete() }
    }
}
