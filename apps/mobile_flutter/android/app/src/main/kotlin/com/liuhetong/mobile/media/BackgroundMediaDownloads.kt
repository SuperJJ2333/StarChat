package com.liuhetong.mobile.media

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ThreadPoolExecutor
import org.json.JSONObject

internal object BackgroundMediaPolicy {
    fun origin(uri: URI): String = "${uri.scheme}://${uri.host}${if (uri.port == -1 || uri.port == 443) "" else ":${uri.port}"}"
    fun allows(url: String, origin: String, kind: String, max: Long, authorization: String?, mediaType: String = "cipher"): Boolean = try {
        val uri = URI(url)
        val path = if (kind == "matrix") Regex("^/_matrix/(client/v1/media|media/v3)/download/[^/]+/.+$")
            else Regex("^/api/v1/moments/media/content/[^/]+$")
        uri.scheme == "https" && uri.host != null && uri.userInfo == null &&
            origin(uri) == origin && path.matches(uri.path) &&
            (kind == "matrix" || kind == "moments") &&
            (if (kind == "matrix") mediaType == "cipher" else mediaType in setOf("image","video")) &&
            (kind == "matrix" || authorization == null) && max in 1..67108864
    } catch (_: Exception) { false }
}

/** Runs under the existing foreground sync service. No Activity or second
 * service is retained. Process death interrupts pending Android transfers;
 * completed private files can be reconciled on the next authenticated start. */
internal class BackgroundMediaDownloads(context: Context,
    private val openConnection: (URL) -> HttpURLConnection = { it.openConnection() as HttpURLConnection }) {
    private val prefs = context.getSharedPreferences("background-media-v1", Context.MODE_PRIVATE)
    private val root = File(context.noBackupFilesDir, "background-media-v1").apply { mkdirs() }
    private val workers = Executors.newFixedThreadPool(2)
    private val interactive = Executors.newFixedThreadPool(1)
    private val main = Handler(Looper.getMainLooper())
    private val entries = ConcurrentHashMap<String, Entry>()
    private val lock = Any()
    private var activeAccount = prefs.getString("account", null)
    private var activeNonce = prefs.getString("nonce", null)
    private var stagedBytes = root.walkTopDown().filter { it.isFile && it.extension == "bin" }.sumOf { it.length() }
    init {
        root.walkTopDown().filter { it.isFile && it.extension == "part" }.forEach { it.delete() }
        reclaimOrphans()
    }
    private data class Entry(val account: String, val nonce: String, val id: String,
        val file: File, var state: String = "pending", var connection: HttpURLConnection? = null,
        var reserved: Long = 0, var work: Runnable? = null)
    private fun current(account: String, nonce: String) = activeAccount == account && activeNonce == nonce
    private fun validId(value: String) = Regex("^[a-f0-9]{64}$").matches(value)
    private fun directory(account: String, nonce: String): File {
        require(validId(account) && Regex("^[a-fA-F0-9-]{36}$").matches(nonce))
        return File(File(root, account), nonce).apply { mkdirs() }
    }
    /** Only unregistered native staging is evictable. Registered complete
     * results may already be read by Dart; active transfers reserve their bytes.
     * Recent orphan results survive restart unless quota needs their space. */
    private fun reclaimOrphans(requiredBytes: Long = 0) {
        val protected = entries.values.map { it.file.absolutePath }.toSet()
        val currentDirectory = if (activeAccount != null && activeNonce != null)
            File(File(root, activeAccount!!), activeNonce!!).absolutePath else null
        val orphans = root.walkTopDown().filter {
            it.isFile && it.extension == "bin" && it.absolutePath !in protected
        }.sortedBy { it.lastModified() }.toList()
        var remaining = orphans.size
        val now = System.currentTimeMillis()
        for (file in orphans) {
            val metadata = File(file.parentFile, "${file.nameWithoutExtension}.json")
            val expired = now - file.lastModified() >= 86400000 ||
                file.parentFile?.absolutePath != currentDirectory || !metadata.exists()
            if (expired || remaining > 192 || stagedBytes + requiredBytes > 268435456) {
                val size = file.length()
                if (file.delete()) {
                    stagedBytes = (stagedBytes - size).coerceAtLeast(0)
                    metadata.delete()
                    remaining--
                }
            }
        }
    }
    private fun clearActive() {
        entries.values.forEach { it.connection?.disconnect() }
        (workers as ThreadPoolExecutor).queue.clear()
        (interactive as ThreadPoolExecutor).queue.clear()
        entries.clear()
        stagedBytes = 0
        // root is a fixed application-owned path, never supplied by Flutter.
        root.listFiles()?.forEach { it.deleteRecursively() }
        activeAccount = null; activeNonce = null
        prefs.edit().remove("account").remove("nonce").commit()
    }
    private fun activate(account: String): String = synchronized(lock) {
        require(validId(account))
        if (account == activeAccount && activeNonce != null) return@synchronized activeNonce!!
        clearActive()
        val nonce = UUID.randomUUID().toString()
        activeAccount = account; activeNonce = nonce
        check(prefs.edit().putString("account", account).putString("nonce", nonce).commit())
        nonce
    }
    private fun enqueue(args: Map<*, *>) = synchronized(lock) {
        val account=args["account"] as String; val nonce=args["nonce"] as String
        val id=args["id"] as String; val url=args["url"] as String
        val origin=args["origin"] as String; val kind=args["kind"] as String
        val mediaType=args["mediaType"] as? String ?: "cipher"
        val max=(args["maxBytes"] as Number).toLong(); val authorization=args["authorization"] as? String
        check(current(account,nonce) && validId(id))
        require(BackgroundMediaPolicy.allows(url,origin,kind,max,authorization,mediaType))
        val existing=entries[id]
        if(existing != null && existing.state != "failed") return@synchronized
        val file=File(directory(account,nonce), "$id.bin")
        val metadata=File(file.parentFile,"$id.json")
        if(file.exists() && metadata.exists() && file.length() in 1..max &&
            System.currentTimeMillis()-file.lastModified()<86400000) {
            entries[id]=Entry(account,nonce,id,file,"complete",reserved=file.length()); return@synchronized
        }
        stagedBytes=(stagedBytes-file.length()).coerceAtLeast(0)
        file.delete(); metadata.delete()
        check(entries.values.count { it.state == "pending" } < 192)
        val entry=Entry(account,nonce,id,file)
        entries[id]=entry
        val work=Runnable { transfer(entry,url,origin,kind,mediaType,max,authorization) }
        entry.work=work; workers.execute(work)
    }
    private fun transfer(entry: Entry, url: String, origin: String, kind: String, mediaType: String, max: Long, authorization: String?) {
        val temp=File(entry.file.parentFile,"${entry.id}.part")
        var connection: HttpURLConnection?=null
        try {
            synchronized(lock) { check(current(entry.account,entry.nonce) && entries[entry.id] === entry) }
            connection=openConnection(URL(url))
            synchronized(lock) {
                check(current(entry.account,entry.nonce) && entries[entry.id] === entry)
                entry.connection=connection
            }
            connection.instanceFollowRedirects=false
            connection.connectTimeout=30000; connection.readTimeout=30000
            if(authorization != null) connection.setRequestProperty("Authorization",authorization)
            check(connection.responseCode == 200)
            check(BackgroundMediaPolicy.origin(connection.url.toURI()) == origin)
            val mime=connection.contentType?.substringBefore(';')?.trim()?.lowercase()
            check(kind == "matrix" || if(mediaType == "video") mime in setOf("video/mp4","video/quicktime")
                else mime in setOf("image/jpeg","image/png","image/webp","image/gif"))
            check(connection.contentLengthLong <= max)
            var size=0L
            connection.inputStream.use { input -> temp.outputStream().use { output ->
                val buffer=ByteArray(32768)
                while(true) {
                    val count=input.read(buffer); if(count == -1) break
                    size+=count; check(size<=max)
                    synchronized(lock) {
                        check(current(entry.account,entry.nonce) && entries[entry.id] === entry)
                        // Bound all staged results, including ones Dart has not yet consumed.
                        if (stagedBytes + count > 268435456) reclaimOrphans(count.toLong())
                        check(stagedBytes + count <= 268435456)
                        stagedBytes += count; entry.reserved += count
                        output.write(buffer,0,count)
                    }
                }
            } }
            check(size>0)
            synchronized(lock) {
                check(current(entry.account,entry.nonce) && entries[entry.id] === entry)
                check(temp.renameTo(entry.file))
                File(entry.file.parentFile,"${entry.id}.json").writeText(JSONObject().put("size",size).toString())
                entry.state="complete"
            }
        } catch (_: Exception) {
            synchronized(lock) {
                if(entries[entry.id] === entry) {
                    entry.state="failed"
                    stagedBytes=(stagedBytes-entry.reserved).coerceAtLeast(0); entry.reserved=0
                    entry.file.delete()
                }
            }
            temp.delete()
        } finally { connection?.disconnect(); entry.connection=null }
    }
    private fun status(args: Map<*, *>): Map<String,Any> = synchronized(lock) {
        val account=args["account"] as String; val nonce=args["nonce"] as String; val id=args["id"] as String
        check(current(account,nonce) && validId(id))
        val entry=entries[id]
        if(entry == null) return@synchronized mapOf("state" to "failed")
        if(entry.state == "complete") mapOf("state" to "complete", "path" to entry.file.absolutePath)
        else mapOf("state" to entry.state)
    }
    fun attach(messenger: BinaryMessenger) {
        MethodChannel(messenger,"chatflow/background_media").setMethodCallHandler { call,result ->
            try {
                val args=call.arguments as? Map<*,*> ?: emptyMap<String,Any>()
                when(call.method) {
                    "activate" -> result.success(activate(args["account"] as String))
                    "enqueue" -> { enqueue(args); result.success(null) }
                    "status" -> result.success(status(args))
                    "promote" -> {
                        synchronized(lock) {
                            check(current(args["account"] as String,args["nonce"] as String))
                            val entry=entries[args["id"] as String]
                            val work=entry?.work
                            if(work != null && (workers as ThreadPoolExecutor).remove(work)) interactive.execute(work)
                        }; result.success(null)
                    }
                    "consume" -> {
                        synchronized(lock) {
                            check(current(args["account"] as String,args["nonce"] as String))
                            val id=args["id"] as String; require(validId(id))
                            entries.remove(id)?.let { entry ->
                                stagedBytes=(stagedBytes-entry.reserved).coerceAtLeast(0)
                                entry.connection?.disconnect(); entry.file.delete()
                                File(entry.file.parentFile,"$id.json").delete()
                            }
                        }; result.success(null)
                    }
                    "revoke" -> {
                        synchronized(lock) {
                            if(current(args["account"] as String,args["nonce"] as String)) clearActive()
                        }; result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) { main.post { result.error("MEDIA_REJECTED","Media request rejected",null) } }
        }
    }
    companion object {
        private var instance: BackgroundMediaDownloads?=null
        fun setUp(context: Context,messenger: BinaryMessenger) {
            val bridge=instance ?: BackgroundMediaDownloads(context.applicationContext).also { instance=it }
            bridge.attach(messenger)
        }
    }
}
