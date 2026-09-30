package com.liuhetong.mobile.media

import java.io.ByteArrayInputStream
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.nio.ByteBuffer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.StandardMethodCodec
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], application = android.app.Application::class, manifest = Config.NONE)
class BackgroundMediaDownloadsTest {
    private class Messenger : BinaryMessenger {
        private var handler: BinaryMessenger.BinaryMessageHandler? = null
        override fun send(channel: String, message: ByteBuffer?) {}
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {}
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) { this.handler=handler }
        fun invoke(method: String, args: Map<String,Any>): Any? {
            val buffer=StandardMethodCodec.INSTANCE.encodeMethodCall(MethodCall(method,args)); buffer.flip()
            var result: Any?=null
            handler!!.onMessage(buffer) { reply -> reply!!.flip(); result=StandardMethodCodec.INSTANCE.decodeEnvelope(reply) }
            return result
        }
    }
    private class Connection(url: URL, val bytes: ByteArray, val gate: CountDownLatch? = null,
        val started: CountDownLatch? = null) : HttpURLConnection(url) {
        var disconnected=false
        override fun connect() {}
        override fun disconnect() { disconnected=true }
        override fun usingProxy()=false
        override fun getResponseCode()=200
        override fun getContentType()="application/octet-stream"
        override fun getContentLengthLong()=-1L // streaming limit must still apply
        override fun getInputStream(): ByteArrayInputStream {
            started?.countDown(); gate?.await(2,TimeUnit.SECONDS)
            return ByteArrayInputStream(bytes)
        }
    }
    private fun args(account:String,nonce:String,id:String="c".repeat(64),max:Long=1024)=mapOf<String,Any>(
        "account" to account,"nonce" to nonce,"id" to id,"url" to "https://matrix.test/_matrix/client/v1/media/download/test/id?allow_redirect=false",
        "origin" to "https://matrix.test","kind" to "matrix","maxBytes" to max,"authorization" to "Bearer test")
    private fun terminal(messenger:Messenger,args:Map<String,Any>):Map<*,*> {
        repeat(200) {
            val status=messenger.invoke("status",args) as Map<*,*>
            if(status["state"]!="pending") return status
            Thread.sleep(5)
        }
        error("Native transfer did not complete")
    }
    @Test fun privateCompletedDownloadSurvivesRecreationAndLogoutFencesOldNonce() {
        val context=RuntimeEnvironment.getApplication()
        val alice="a".repeat(64); val bob="b".repeat(64)
        var opens=0
        val first=Messenger()
        BackgroundMediaDownloads(context) { url -> opens++; Connection(url,byteArrayOf(1,2,3)) }.attach(first)
        val nonce=first.invoke("activate",mapOf("account" to alice)) as String
        val args=args(alice,nonce)
        first.invoke("enqueue",args)
        val status=terminal(first,args)
        assertEquals("complete",status["state"])
        val file=File(status["path"] as String)
        assertTrue(file.canonicalPath.startsWith(context.noBackupFilesDir.canonicalPath+File.separator))
        assertTrue(file.readBytes().contentEquals(byteArrayOf(1,2,3)))
        val restored=Messenger()
        BackgroundMediaDownloads(context) { url -> opens++; Connection(url,byteArrayOf(9)) }.attach(restored)
        assertEquals(nonce,restored.invoke("activate",mapOf("account" to alice)))
        restored.invoke("enqueue",args)
        assertEquals("complete",terminal(restored,args)["state"])
        assertEquals(1,opens)
        restored.invoke("revoke",args)
        assertFalse(file.exists())
        val next=restored.invoke("activate",mapOf("account" to bob)) as String
        restored.invoke("revoke",args)
        assertEquals(next,restored.invoke("activate",mapOf("account" to bob)))
        assertNotEquals(nonce,next)
        restored.invoke("revoke",mapOf("account" to bob,"nonce" to next))
    }
    @Test fun streamedOversizeAndLateCanceledResultNeverProduceACompletedFile() {
        val context=RuntimeEnvironment.getApplication(); val alice="a".repeat(64)
        val messenger=Messenger()
        BackgroundMediaDownloads(context) { url -> Connection(url,ByteArray(2048)) }.attach(messenger)
        val nonce=messenger.invoke("activate",mapOf("account" to alice)) as String
        val request=args(alice,nonce,max=1024)
        messenger.invoke("enqueue",request)
        assertEquals("failed",terminal(messenger,request)["state"])
        messenger.invoke("revoke",request)
        val gate=CountDownLatch(1); val started=CountDownLatch(1)
        lateinit var connection:Connection
        val delayed=Messenger()
        BackgroundMediaDownloads(context) { url -> Connection(url,byteArrayOf(1),gate,started).also { connection=it } }.attach(delayed)
        val lateNonce=delayed.invoke("activate",mapOf("account" to alice)) as String
        val late=args(alice,lateNonce)
        delayed.invoke("enqueue",late)
        assertTrue(started.await(2,TimeUnit.SECONDS))
        delayed.invoke("revoke",late); gate.countDown()
        assertTrue(connection.disconnected)
        Thread.sleep(30)
        assertFalse(File(context.noBackupFilesDir,"background-media-v1/$alice/$lateNonce").exists())
    }
    @Test fun restartReclaimsOrphanQuotaWhileProtectingReattachedRecentResult() {
        val context=RuntimeEnvironment.getApplication(); val account="a".repeat(64)
        val first=Messenger()
        BackgroundMediaDownloads(context) { url -> Connection(url,byteArrayOf(1,2,3)) }.attach(first)
        val nonce=first.invoke("activate",mapOf("account" to account)) as String
        val directory=File(context.noBackupFilesDir,"background-media-v1/$account/$nonce").apply { mkdirs() }
        fun staged(id:String,size:Long,age:Long):File {
            val file=File(directory,"$id.bin")
            java.io.RandomAccessFile(file,"rw").use { it.setLength(size) }
            File(directory,"$id.json").writeText("{\"size\":$size}")
            file.setLastModified(System.currentTimeMillis()-age)
            return file
        }
        val orphan=staged("d".repeat(64),268435448L,2*60*60*1000L)
        val recent=staged("e".repeat(64),8,1000)
        val expired=staged("f".repeat(64),3,25*60*60*1000L)
        val restored=Messenger()
        BackgroundMediaDownloads(context) { url -> Connection(url,byteArrayOf(1,2,3)) }.attach(restored)
        assertEquals(nonce,restored.invoke("activate",mapOf("account" to account)))
        val recentRequest=args(account,nonce,"e".repeat(64))
        restored.invoke("enqueue",recentRequest)
        assertEquals("complete",terminal(restored,recentRequest)["state"])
        val fresh=args(account,nonce)
        restored.invoke("enqueue",fresh)
        assertEquals("complete",terminal(restored,fresh)["state"])
        assertFalse(orphan.exists())
        assertFalse(expired.exists())
        assertTrue(recent.exists(),"A registered result may be read by Dart and must not be evicted")
        restored.invoke("revoke",fresh)
    }

}
