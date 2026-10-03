package com.liuhetong.mobile.push

import android.app.*
import android.content.*
import android.database.sqlite.SQLiteDatabase
import android.net.Uri
import android.os.*
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.liuhetong.mobile.MainActivity
import com.liuhetong.mobile.call.CallManager
import io.flutter.plugin.common.*
import org.json.JSONObject
import java.security.SecureRandom
import java.util.Calendar
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** All methods of the owner execute on one worker, never the UI/SDK push process.
 * SQLite row transactions avoid rewriting the entire dedup/policy map per event. */
internal class NativeMessageOwner(private val context: Context) {
    private val db = context.openOrCreateDatabase("native_messages.db", 0, null)
    private val manager = context.getSystemService(NotificationManager::class.java)
    var foreground = false
    var callActive: () -> Boolean = { CallManager.hasActiveCall() }
    private var unsafe = false
    private var scope = ""
    private var revision = 0L
    private var minimumRevision = 0L
    private var policy = JSONObject()
    init {
        db.execSQL("CREATE TABLE IF NOT EXISTS state (id INTEGER PRIMARY KEY, account TEXT, scope TEXT, revision INTEGER, valid INTEGER, policy TEXT)")
        db.execSQL("CREATE TABLE IF NOT EXISTS rooms (key TEXT PRIMARY KEY, muted INTEGER)")
        db.execSQL("CREATE TABLE IF NOT EXISTS claims (key TEXT PRIMARY KEY, room TEXT, at INTEGER, status INTEGER)")
        db.execSQL("CREATE INDEX IF NOT EXISTS claims_at ON claims(at)")
        db.execSQL("CREATE INDEX IF NOT EXISTS claims_room_status_at ON claims(room,status,at)")
        db.execSQL("CREATE TABLE IF NOT EXISTS tap (id INTEGER PRIMARY KEY, scope TEXT, room TEXT, event TEXT, at INTEGER)")
        db.execSQL("CREATE TABLE IF NOT EXISTS presentations (key TEXT PRIMARY KEY, lease TEXT, at INTEGER)")
        db.rawQuery("SELECT scope, revision, valid, policy FROM state WHERE id=1", null).use {
            if (it.moveToFirst()) {
                scope = it.getString(0); revision = it.getLong(1); unsafe = it.getInt(2) != 1
                policy = runCatching { JSONObject(it.getString(3)) }.getOrDefault(JSONObject())
            }
        }
        // A previous engine may have shown a banner before losing its ACK.
        // Recover visibility without making a second disruptive alert.
        transaction {
            db.execSQL("UPDATE claims SET status=6 WHERE status=4")
            db.execSQL("DELETE FROM presentations")
        }
        prune()
    }
    private fun transaction(action: () -> Unit) {
        db.beginTransaction()
        try { action(); db.setTransactionSuccessful() } finally { db.endTransaction() }
    }
    fun bind(account: String): String {
        require(hex(account))
        val previous = db.rawQuery("SELECT account FROM state WHERE id=1", null).use {
            if (it.moveToFirst()) it.getString(0) else null
        }
        if (previous == account && hex(scope)) return scope
        revoke()
        scope = ByteArray(32).also { SecureRandom().nextBytes(it) }.joinToString("") { "%02x".format(it.toInt() and 255) }
        db.execSQL("INSERT OR REPLACE INTO state VALUES(1,?,?,0,0,'{}')", arrayOf(account, scope))
        return scope
    }
    fun currentRevision() = revision
    fun currentScope() = scope
    fun valid(value: String) = hex(value) && scope == value && !unsafe
    fun invalidate(value: String, minimum: Long = 0L) {
        if (value != scope) return
        minimumRevision = maxOf(minimumRevision, minimum)
        unsafe = true // Remains restrictive if disk write fails.
        cancelAll()
        db.execSQL("UPDATE state SET valid=0 WHERE id=1")
    }
    fun install(args: Map<*, *>): Boolean {
        val value = args["scope"] as? String ?: return false
        val next = (args["revision"] as? Number)?.toLong() ?: return false
        if (value != scope || !hex(scope) || next <= revision || next < minimumRevision) return false
        // Invalidate before parsing/persistence: a malformed replacement cannot leave old sound active.
        invalidate(value)
        val rooms = args["rooms"] as? Map<*, *> ?: return false
        if (rooms.size > 2048 || rooms.any { !hex(it.key as? String ?: "") || it.value !is Boolean }) return false
        if (listOf("enabled", "sound", "vibration", "dnd").any { args[it] !is Boolean }) return false
        val start = args["start"] as? Int ?: return false
        val end = args["end"] as? Int ?: return false
        if (start !in 0..1439 || end !in 0..1439) return false
        val nextPolicy = JSONObject().apply {
            for (key in listOf("enabled", "sound", "vibration", "dnd", "start", "end")) put(key, args[key])
        }
        transaction {
            db.execSQL("DELETE FROM rooms")
            rooms.forEach { (key, muted) -> db.execSQL("INSERT INTO rooms VALUES(?,?)", arrayOf(key, if (muted == true) 1 else 0)) }
            db.execSQL("UPDATE state SET revision=?, valid=1, policy=? WHERE id=1", arrayOf<Any>(next, nextPolicy.toString()))
        }
        policy = nextPolicy; revision = next; unsafe = false
        retryPending()
        return true
    }
    fun room(value: String, key: String, muted: Boolean, next: Long): Boolean {
        if (!valid(value) || !hex(key) || next <= revision) return false
        // Small durable delta; serialize against receive so mute cannot race the next display.
        if (muted) cancelRoom(key)
        val exists = db.rawQuery("SELECT 1 FROM rooms WHERE key=?", arrayOf(key)).use { it.moveToFirst() }
        val count = db.rawQuery("SELECT COUNT(*) FROM rooms", null).use { it.moveToFirst(); it.getInt(0) }
        if (!exists && count >= 2048) return false
        try {
            transaction {
                db.execSQL("INSERT OR REPLACE INTO rooms VALUES(?,?)", arrayOf<Any>(key, if (muted) 1 else 0))
                db.execSQL("UPDATE state SET revision=? WHERE id=1", arrayOf(next))
            }
            revision = next
            return true
        } catch (error: Exception) { invalidate(value); throw error }
    }
    fun revoke() {
        unsafe = true; cancelAll()
        transaction {
            for (table in listOf("state", "rooms", "claims", "tap", "presentations")) db.execSQL("DELETE FROM $table")
        }
        scope = ""; revision = 0; minimumRevision = 0; policy = JSONObject()
    }
    private fun prune() {
        val now = System.currentTimeMillis()
        db.execSQL("UPDATE claims SET status=6 WHERE status=4 AND key NOT IN (SELECT key FROM presentations WHERE at>? AND at<=?)", arrayOf(now - 5000, now))
        db.execSQL("DELETE FROM presentations WHERE at<=? OR at>? OR key NOT IN (SELECT key FROM claims WHERE status=4)", arrayOf(now - 5000, now))
        db.execSQL("DELETE FROM claims WHERE at<? OR at>?", arrayOf(now - 600_000, now + 30_000))
        // Displayed claims outlive pending recovery. Persistently retire an
        // older uncertain item even after the newer system item was dismissed.
        db.execSQL("UPDATE claims SET status=2 WHERE status=6 AND EXISTS (SELECT 1 FROM claims AS newer WHERE newer.room=claims.room AND newer.key<>claims.key AND newer.status=3 AND newer.at>=claims.at)")
        db.execSQL("UPDATE claims SET status=2 WHERE status=6 AND at<?", arrayOf(now - 300_000))
        db.execSQL("DELETE FROM claims WHERE status IN (0,1) AND at<?", arrayOf(now - 300_000))
        trimPending()
        db.execSQL("DELETE FROM tap WHERE at<? OR at>?", arrayOf(now - 300_000, now + 30_000))
    }
    private fun trimPending() {
        // Keep uncertainty as a handled tombstone on overflow, never turn a
        // retried uncertain event back into a fresh audible delivery.
        db.execSQL("UPDATE claims SET status=2 WHERE status=6 AND key NOT IN (SELECT key FROM claims WHERE status IN (0,6) ORDER BY at DESC LIMIT 32)")
        db.execSQL("DELETE FROM claims WHERE status=0 AND key NOT IN (SELECT key FROM claims WHERE status IN (0,6) ORDER BY at DESC LIMIT 32)")
    }
    private fun status(key: String): Int? = db.rawQuery("SELECT status,at FROM claims WHERE key=?", arrayOf(key)).use {
        if (!it.moveToFirst()) null
        else if (it.getInt(0) == 1 && System.currentTimeMillis() - it.getLong(1) >= 5000) 0 else it.getInt(0)
    }
    private fun record(key: String, room: String, status: Int): Boolean {
        prune()
        val count = db.rawQuery("SELECT COUNT(*) FROM claims", null).use { it.moveToFirst(); it.getInt(0) }
        if (count >= 4096 && this.status(key) == null) return false
        db.execSQL("INSERT OR REPLACE INTO claims VALUES(?,?,?,?)", arrayOf<Any>(key, room, System.currentTimeMillis(), status))
        // Pending-only queue cap; overflow never turns an already handled claim into audible default.
        trimPending()
        return true
    }
    fun claim(value: String, room: String, event: String): Boolean {
        if (!valid(value) || !hex(room) || !hex(event)) return false
        prune()
        if ((status(event) ?: 0) != 0) return false
        return record(event, room, 1)
    }
    fun complete(value: String, event: String) {
        if (!valid(value) || status(event) != 1) return
        db.execSQL("UPDATE claims SET status=2 WHERE key=?", arrayOf(event))
    }
    fun beginForeground(value: String, event: String): String? {
        if (!valid(value) || !foreground || callActive() || status(event) != 1) return null
        val lease = java.util.UUID.randomUUID().toString()
        transaction {
            db.execSQL("INSERT OR REPLACE INTO presentations VALUES(?,?,?)", arrayOf<Any>(event,lease,System.currentTimeMillis()))
            db.execSQL("UPDATE claims SET status=4 WHERE key=?", arrayOf(event))
        }
        return lease
    }
    fun finishForeground(value: String, event: String, lease: String, handled: Boolean) {
        // A known abort must release even during restrictive policy installation.
        // Scope and attempt identity remain authoritative while valid=false.
        if (!hex(value) || value != scope || !hex(event)) return
        val matches = db.rawQuery("SELECT 1 FROM presentations WHERE key=? AND lease=?",arrayOf(event,lease)).use { it.moveToFirst() }
        if (!matches || status(event) != 4) return
        transaction {
            db.execSQL("UPDATE claims SET status=? WHERE key=?", arrayOf<Any>(if (handled) 2 else 0, event))
            db.execSQL("DELETE FROM presentations WHERE key=? AND lease=?",arrayOf(event,lease))
        }
        if (!handled) retryPending()
    }
    fun resolve(value: String, room: String, event: String, show: Boolean, silent: Boolean,
                title: String = "畅聊", body: String = "您有一条新消息"): Boolean {
        if (!valid(value) || !hex(room) || !hex(event)) return false
        prune()
        if (status(event) == 3) {
            val visible = manager.activeNotifications.any { it.tag == "native_message" && it.id == id(room) &&
                it.notification.extras.getString("native_event") == event }
            if (visible && show && !foreground) present(value, room, event, silent, title, body, true)
            return false
        }
        if ((status(event) ?: 0) != 0) return false
        if (!record(event, room, if (show) 0 else 2)) return false
        if (show && !foreground) present(value, room, event, silent, title, body)
        return status(event) == 3 || !show
    }
    fun receive(value: String, room: String, event: String) {
        if (!valid(value) || !hex(room) || !hex(event)) return
        prune()
        val uncertain = status(event) == 6
        if ((status(event) ?: 0) != 0 && !uncertain) return
        if (!record(event, room, if (uncertain) 6 else 0)) return
        if (foreground || callActive()) return
        if (uncertain && manager.activeNotifications.any { it.tag == "native_message" && it.id == id(room) && it.notification.extras.getString("native_event") != event }) {
            db.execSQL("UPDATE claims SET status=2 WHERE key=?",arrayOf(event))
            return
        }
        present(value, room, event, forceQuiet = uncertain)
    }
    fun retryPending() {
        prune()
        if (foreground || callActive() || unsafe) return
        val pending = mutableListOf<Pair<String,String>>()
        db.rawQuery("SELECT key,room FROM claims WHERE status IN (0,6) OR (status=1 AND at<?) LIMIT 32", arrayOf((System.currentTimeMillis() - 5000).toString())).use {
            while (it.moveToNext()) pending.add(it.getString(0) to it.getString(1))
        }
        for ((event, room) in pending) receive(scope, room, event)
    }
    private fun present(value: String, room: String, event: String, forceQuiet: Boolean = false,
                        title: String = "畅聊", body: String = "您有一条新消息", updating: Boolean = false) {
        if (!valid(value) || callActive()) return
        if (!policy.optBoolean("enabled")) {
            db.execSQL("UPDATE claims SET status=2 WHERE key=?", arrayOf(event))
            return
        }
        val muted = db.rawQuery("SELECT muted FROM rooms WHERE key=?", arrayOf(room)).use {
            !it.moveToFirst() || it.getInt(0) != 0
        }
        val c = Calendar.getInstance()
        val minute = c.get(Calendar.HOUR_OF_DAY) * 60 + c.get(Calendar.MINUTE)
        val start = policy.optInt("start"); val end = policy.optInt("end")
        val dnd = policy.optBoolean("dnd") && start != end &&
            (if (start < end) minute >= start && minute < end else minute >= start || minute < end)
        val quiet = forceQuiet || muted || dnd
        val sound = !quiet && policy.optBoolean("sound")
        val vibration = !quiet && policy.optBoolean("vibration")
        val channel = if (quiet) "chatflow_silent" else when {
            sound && vibration -> "chatflow_messages_v2"
            sound -> "chatflow_messages_sound_v1"
            vibration -> "chatflow_messages_vibrate_v1"
            else -> "chatflow_messages_quiet_v1"
        }
        createChannel(channel, sound, vibration, quiet)
        if (!NotificationManagerCompat.from(context).areNotificationsEnabled() ||
            (Build.VERSION.SDK_INT >= 26 && manager.getNotificationChannel(channel)?.importance == NotificationManager.IMPORTANCE_NONE)) return
        val intent = Intent(context, MainActivity::class.java).apply {
            action = NativeMessageNotifications.tapAction
            data = Uri.parse("chatflow-native://tap/$value/$room/$event")
            putExtra("scope", value); putExtra("room_key", room); putExtra("event_key", event)
            addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        val pending = PendingIntent.getActivity(context, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val icon = context.resources.getIdentifier("ic_launcher", "mipmap", context.packageName)
        val notification = NotificationCompat.Builder(context, channel)
            .setSmallIcon(if (icon != 0) icon else android.R.drawable.sym_action_chat)
            // These already privacy-filtered previews arrive only from the local decrypted client.
            // They are never stored in SQLite or forwarded to the provider.
            .setContentTitle(title.take(256)).setContentText(body.take(2048))
            .setOnlyAlertOnce(updating)
            .addExtras(Bundle().apply { putString("native_event", event) })
            .setCategory(NotificationCompat.CATEGORY_MESSAGE).setAutoCancel(true)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPriority(if (quiet) NotificationCompat.PRIORITY_LOW else NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(pending).setSound(if (sound) soundUri() else null)
            .setVibrate(if (vibration) longArrayOf(0, 400, 200, 400) else longArrayOf(0)).build()
        try {
            if (Build.VERSION.SDK_INT >= 23) {
                val existing = manager.activeNotifications.filter { it.tag == "native_message" }
                if (existing.size >= 32 && existing.none { it.id == id(room) }) {
                    existing.minByOrNull { it.postTime }?.let { manager.cancel(it.tag, it.id) }
                }
            }
            manager.notify("native_message", id(room), notification)
            db.execSQL("UPDATE claims SET status=3 WHERE key=?", arrayOf(event))
        } catch (_: SecurityException) { /* Permission recovery can retry; never mark displayed. */ }
    }
    private fun soundUri() = Uri.parse("android.resource://${context.packageName}/raw/chatflow_message")
    private fun createChannel(id: String, sound: Boolean, vibration: Boolean, quiet: Boolean) {
        if (Build.VERSION.SDK_INT < 26) return
        val channel = NotificationChannel(id, if (quiet) "后台服务" else "消息通知", if (quiet) NotificationManager.IMPORTANCE_LOW else NotificationManager.IMPORTANCE_HIGH)
        channel.setSound(if (sound) soundUri() else null, android.media.AudioAttributes.Builder().setUsage(android.media.AudioAttributes.USAGE_NOTIFICATION).build())
        channel.enableVibration(vibration)
        if (vibration) channel.vibrationPattern = longArrayOf(0,400,200,400)
        manager.createNotificationChannel(channel) // Existing user channel overrides remain authoritative.
    }
    private fun id(room: String) = room.take(8).toLong(16).toInt() and Int.MAX_VALUE
    fun cancelRoom(room: String) { if (hex(room)) manager.cancel("native_message", id(room)) }
    private fun cancelAll() {
        if (Build.VERSION.SDK_INT >= 23) for (entry in manager.activeNotifications) {
            if (entry.tag == "native_message") manager.cancel(entry.tag, entry.id)
        }
    }
    fun tap(value: String, room: String, event: String): Boolean {
        if (!valid(value) || !hex(room) || !hex(event)) return false
        db.execSQL("INSERT OR REPLACE INTO tap VALUES(1,?,?,?,?)", arrayOf<Any>(value,room,event,System.currentTimeMillis()))
        return true
    }
    fun takeTap(): Map<String,String>? {
        prune()
        val result = db.rawQuery("SELECT scope,room,event FROM tap WHERE id=1",null).use {
            if (it.moveToFirst() && valid(it.getString(0))) mapOf("scope" to it.getString(0), "room_key" to it.getString(1), "event_key" to it.getString(2)) else null
        }
        db.execSQL("DELETE FROM tap")
        return result
    }
    fun close() = db.close()
    companion object { fun hex(value: String) = value.matches(Regex("[0-9a-f]{64}")) }
}

object NativeMessageNotifications {
    const val tapAction = "com.liuhetong.mobile.NATIVE_MESSAGE_TAP"
    private val worker = Executors.newSingleThreadScheduledExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var owner: NativeMessageOwner? = null
    private var channel: MethodChannel? = null
    @Volatile private var foreground = false
    private fun owner(context: Context) = owner ?: NativeMessageOwner(context.applicationContext).also { owner = it }
    fun attach(context: Context, messenger: BinaryMessenger) {
        val next = MethodChannel(messenger, "chatflow/native_messages")
        channel = next
        next.setMethodCallHandler { call, result ->
            worker.execute {
                try {
                    val o = owner(context)
                    o.foreground = foreground
                    val a = call.arguments as? Map<*, *> ?: emptyMap<Any,Any>()
                    val scope = a["scope"] as? String ?: ""
                    val room = a["room_key"] as? String ?: ""
                    val event = a["event_key"] as? String ?: ""
                    val value: Any? = when(call.method) {
                        "bind" -> mapOf("scope" to o.bind(a["account"] as? String ?: ""), "revision" to o.currentRevision())
                        "install" -> o.install(a)
                        "invalidate" -> { o.invalidate(scope, (a["revision"] as? Number)?.toLong() ?: 0); true }
                        "revoke" -> { o.revoke(); true }
                        "room" -> o.room(scope, room, a["muted"] == true, (a["revision"] as? Number)?.toLong() ?: 0)
                        "claim" -> o.claim(scope, room, event).also {
                            worker.schedule({ runCatching { o.retryPending() } }, 5, TimeUnit.SECONDS)
                        }
                        "complete" -> { o.complete(scope,event); true }
                        "beginForeground" -> o.beginForeground(scope,event).also {
                            worker.schedule({ runCatching { o.retryPending() } }, 5, TimeUnit.SECONDS)
                        }
                        "finishForeground" -> { o.finishForeground(scope,event,a["lease"] as? String ?: "",a["handled"] == true); true }
                        "resolve" -> o.resolve(scope, room, event, a["show"] == true, a["silent"] == true,
                            a["title"] as? String ?: "畅聊", a["body"] as? String ?: "您有一条新消息")
                        "cancelRoom" -> { if (o.valid(scope)) o.cancelRoom(room); true }
                        "takeTap" -> if (foreground && o.valid(scope)) o.takeTap() else null
                        "validate" -> o.valid(scope)
                        else -> null
                    }
                    main.post { result.success(value) }
                } catch (_: Exception) { main.post { result.error("NATIVE_MESSAGE_STATE", "Notification state unavailable", null) } }
            }
        }
    }
    fun receive(context: Context, payload: JSONObject) {
        if (payload.opt("v") !is Int || payload.optInt("v") != 1) return
        val scope = payload.optString("scope"); val room = payload.optString("room_key"); val event = payload.optString("event_key")
        worker.execute {
            runCatching { owner(context).apply { this.foreground = NativeMessageNotifications.foreground }.receive(scope,room,event) }
        }
        worker.schedule({ runCatching { owner(context).retryPending() } }, 5, TimeUnit.SECONDS)
    }
    fun lifecycle(context: Context, resumed: Boolean) {
        foreground = resumed
        worker.execute { runCatching { owner(context).apply { foreground = resumed }.retryPending() } }
    }
    fun acceptIntent(context: Context, intent: Intent?) {
        if (intent?.action != tapAction) return
        val scope = intent.getStringExtra("scope") ?: return
        val room = intent.getStringExtra("room_key") ?: return
        val event = intent.getStringExtra("event_key") ?: return
        intent.action = null // Consume once; Dart polls only after active authenticated readiness.
        worker.execute {
            if (runCatching { owner(context).tap(scope,room,event) }.getOrDefault(false)) {
                main.post { channel?.invokeMethod("tapAvailable", null) }
            }
        }
    }
}

