package com.liuhetong.mobile.update

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.os.StatFs
import android.provider.Settings
import android.util.Base64
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.cert.CertificateFactory
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** One worker; private files; only status strings cross the Flutter bridge. */
class AndroidDeltaUpdate(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "chatflow/android_delta")
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor { task -> Thread(task, "apk-delta").apply { isDaemon = true } }
    private val busy = AtomicBoolean(false)
    @Volatile private var ready: File? = null
    private val gate = DeltaWorkGate()
    private val directory = File(activity.filesDir, "verified_updates").apply { mkdirs() }

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "prepare" -> {
                    val envelope = call.argument<Map<String, Any?>>("delta")
                    if (envelope == null || !busy.compareAndSet(false, true)) result.success("fallback")
                    else {
                        gate.restart()
                        ready = null
                        worker.execute {
                            Process.setThreadPriority(Process.THREAD_PRIORITY_BACKGROUND)
                            val status = try { prepare(envelope); "ready" }
                            catch (_: InterruptedException) { "cancelled" }
                            catch (_: Exception) { "fallback" }
                            finally { busy.set(false) }
                            main.post { result.success(status) }
                        }
                    }
                }
                "install" -> result.success(install())
                "permission" -> {
                    if (Build.VERSION.SDK_INT >= 26) activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                        Uri.parse("package:${activity.packageName}")))
                    result.success(null)
                }
                "paused" -> { gate.pause(call.argument<Boolean>("value") != false); result.success(null) }
                "cancel" -> { cancel(); result.success(null) }
                else -> result.notImplemented()
            }
        }
    }
    private fun checkpoint() = gate.checkpoint()
    private fun cancel() = gate.cancel()
    fun foreground(value: Boolean) = gate.foreground(value)
    fun pressure() { cancel() }
    fun close() { gate.close(); channel.setMethodCallHandler(null); worker.shutdownNow() }

    @Suppress("DEPRECATION")
    private fun flags(): Int = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
    @Suppress("DEPRECATION")
    private fun certificates(info: PackageInfo): List<ByteArray> =
        if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners?.map { it.toByteArray() } ?: emptyList()
        else info.signatures?.map { it.toByteArray() } ?: emptyList()
    @Suppress("DEPRECATION")
    private fun build(info: PackageInfo): Long = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()

    private data class Descriptor(val baseSize: Long, val targetSize: Long, val patchSize: Long,
                                  val baseHash: String, val targetHash: String, val patchHash: String,
                                  val packageName: String, val targetBuild: Long, val certificate: String, val url: String)
    private fun descriptor(envelope: Map<String, Any?>, installed: PackageInfo): Descriptor {
        val payload = envelope["signed_payload"] as? String ?: error("unsigned manifest")
        val signature = envelope["signature"] as? String ?: error("unsigned manifest")
        require(payload.length <= 16384 && signature.length <= 2048)
        val certs = certificates(installed)
        // First format deliberately supports a single existing RSA signer. Rotations/multi-signer use full APK.
        require(certs.size == 1)
        val cert = CertificateFactory.getInstance("X.509").generateCertificate(certs.single().inputStream())
        require(DeltaTrust.verify(payload.toByteArray(Charsets.UTF_8), Base64.decode(signature, Base64.NO_WRAP), cert.publicKey)) { "untrusted manifest" }
        val json = JSONObject(payload)
        fun hash(key: String): String = json.getString(key).also { require(it.matches(Regex("[0-9a-f]{64}"))) }
        fun size(key: String): Long = json.getLong(key).also { require(it in 1..DeltaApplier.MAX_SIZE) }
        require(json.getString("format") == "CFDELTA1")
        val d = Descriptor(size("base_size"), size("target_size"), size("patch_size"), hash("base_sha256"), hash("target_sha256"),
            hash("patch_sha256"), json.getString("package_name"), json.getLong("target_build"), hash("certificate_sha256"), json.getString("patch_url"))
        require(d.packageName == activity.packageName && d.targetBuild > build(installed))
        require(d.certificate == DeltaApplier.hex(DeltaApplier.sha256(certs.single())))
        require(d.patchSize * 5 < d.targetSize * 4) { "inefficient patch" }
        val uri = Uri.parse(d.url)
        // URL is signed by the installed key, HTTPS still required; redirects are forbidden.
        require(uri.scheme == "https" && !uri.host.isNullOrBlank() && uri.userInfo == null && uri.fragment == null && d.url.length <= 2048)
        return d
    }
    private fun prepare(envelope: Map<String, Any?>) {
        val pm = activity.packageManager
        val installed = pm.getPackageInfo(activity.packageName, flags())
        require(installed.applicationInfo?.splitSourceDirs.isNullOrEmpty()) { "split baseline" }
        val d = descriptor(envelope, installed)
        val base = File(requireNotNull(installed.applicationInfo?.sourceDir))
        require(base.length() == d.baseSize && DeltaApplier.hash(base, ::checkpoint) == d.baseHash)
        require(DeltaPolicy.enoughSpace(StatFs(directory.path).availableBytes, d.patchSize, d.targetSize)) { "disk space" }
        val patch = File(directory, "${d.patchHash}.delta")
        val target = File(directory, "${d.targetHash}.apk")
        // Keep at most this release's files, on worker; files are never caller-selected paths.
        directory.listFiles()?.filter { it != patch && it != target }?.forEach { it.delete() }
        if (!patch.exists() || patch.length() != d.patchSize || DeltaApplier.hash(patch, ::checkpoint) != d.patchHash) {
            patch.delete(); download(d, patch)
        }
        if (!target.exists() || target.length() != d.targetSize || DeltaApplier.hash(target, ::checkpoint) != d.targetHash) {
            target.delete()
            DeltaApplier.verifyHeader(patch, d.baseSize, d.targetSize, d.baseHash, d.targetHash)
            DeltaApplier.apply(base, patch, target, ::checkpoint)
        }
        try {
            require(target.length() == d.targetSize && DeltaApplier.hash(target, ::checkpoint) == d.targetHash)
            val archive = pm.getPackageArchiveInfo(target.path, flags()) ?: error("invalid APK")
            val installedHashes = certificates(installed).map { DeltaApplier.hex(DeltaApplier.sha256(it)) }.toSet()
            val archiveHashes = certificates(archive).map { DeltaApplier.hex(DeltaApplier.sha256(it)) }.toSet()
            require(DeltaPolicy.validTarget(d.packageName, d.targetBuild, installedHashes, archive.packageName, build(archive), archiveHashes, build(installed)))
            checkpoint()
            // A baseline may have been replaced while the worker ran; never install against stale identity.
            val current = pm.getPackageInfo(activity.packageName, flags())
            require(build(current) == build(installed) && certificates(current).map { DeltaApplier.hex(DeltaApplier.sha256(it)) }.toSet() == installedHashes)
            ready = target
        } catch (error: Exception) { target.delete(); throw error }
    }
    private fun download(d: Descriptor, patch: File) {
        val part = File(directory, patch.name + ".part")
        val connection = URL(d.url).openConnection() as HttpURLConnection
        try {
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 15000; connection.readTimeout = 15000
            connection.setRequestProperty("Accept-Encoding", "identity")
            require(connection.responseCode == 200)
            require(connection.contentEncoding == null || connection.contentEncoding == "identity")
            require(connection.contentLengthLong == -1L || connection.contentLengthLong == d.patchSize)
            connection.inputStream.use { input ->
                FileOutputStream(part).use { out ->
                    val buffer = ByteArray(DeltaApplier.BUFFER)
                    var total = 0L
                    while (true) {
                        checkpoint(); val n = input.read(buffer); if (n < 0) break
                        require(n.toLong() <= d.patchSize - total) { "oversize download" }
                        out.write(buffer, 0, n); total += n
                    }
                    require(total == d.patchSize); out.fd.sync()
                }
            }
            require(DeltaApplier.hash(part, ::checkpoint) == d.patchHash) { "corrupt patch" }
            require(part.renameTo(patch))
        } finally { connection.disconnect(); part.delete() }
    }
    private fun install(): String {
        if (gate.isCancelled || busy.get()) return "cancelled"
        val apk = ready?.takeIf { it.isFile } ?: return "fallback"
        if (DeltaPolicy.installAction(Build.VERSION.SDK_INT, Build.VERSION.SDK_INT < 26 || activity.packageManager.canRequestPackageInstalls()) == "permission_required") return "permission_required"
        return try {
            val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.verified_updates", apk)
            activity.startActivity(Intent(Intent.ACTION_INSTALL_PACKAGE).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                flags = Intent.FLAG_GRANT_READ_URI_PERMISSION
            })
            "installer_opened"
        } catch (_: Exception) { "fallback" }
    }
}
