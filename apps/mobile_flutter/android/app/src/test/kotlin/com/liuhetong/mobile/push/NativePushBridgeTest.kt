package com.liuhetong.mobile.push

import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.StandardMethodCodec
import java.nio.ByteBuffer
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import kotlin.test.assertEquals
import kotlin.test.assertTrue

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], application = android.app.Application::class, manifest = Config.NONE)
class NativePushBridgeTest {
    private val app get() = RuntimeEnvironment.getApplication()
    private val messenger = Messenger()
    private fun idle() = shadowOf(Looper.getMainLooper()).idle()

    @Before fun before() {
        NativePushBridge.teardown()
        app.getSharedPreferences("pending_push_wakes", 0).edit().clear().commit()
    }
    @After fun after() { NativePushBridge.teardown() }

    private class Messenger : BinaryMessenger {
        val sent = mutableListOf<String>()
        val replies = mutableListOf<BinaryMessenger.BinaryReply?>()
        private var handler: BinaryMessenger.BinaryMessageHandler? = null
        override fun send(channel: String, message: ByteBuffer?) = send(channel, message, null)
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {
            message!!.flip()
            sent.add(StandardMethodCodec.INSTANCE.decodeMethodCall(message).method)
            replies.add(callback)
        }
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {
            this.handler = handler
        }
        fun invoke(method: String) {
            val data = StandardMethodCodec.INSTANCE.encodeMethodCall(MethodCall(method, null))
            data.flip()
            handler?.onMessage(data) {}
        }
        fun ack(index: Int, value: Boolean) {
            val data = StandardMethodCodec.INSTANCE.encodeSuccessEnvelope(value)
            data.flip()
            replies[index]?.reply(data)
        }
    }

    @Test fun coldStartWaitsForDartAndCoalescesWakes() {
        repeat(3) { NativePushBridge.notifyFlutter(app, "pushMessage") }
        idle()
        NativePushBridge.setUp(messenger)
        idle()
        assertTrue(messenger.sent.isEmpty())
        messenger.invoke("pushListenerReady")
        idle()
        assertEquals(listOf("pushMessage"), messenger.sent)
        messenger.ack(0, true)
        idle()
        messenger.invoke("pushListenerReady")
        idle()
        assertEquals(1, messenger.sent.size)
    }

    @Test fun failedDeliveryAndEngineReplacementRetainWake() {
        NativePushBridge.notifyFlutter(app, "pushMessage")
        idle()
        NativePushBridge.setUp(messenger)
        messenger.invoke("pushListenerReady")
        idle()
        assertEquals(1, messenger.sent.size)
        messenger.ack(0, false)
        idle()
        NativePushBridge.teardown()
        val next = Messenger()
        NativePushBridge.setUp(next)
        next.invoke("pushListenerReady")
        idle()
        assertEquals(listOf("pushMessage"), next.sent)
    }

    @Test fun oldAcknowledgementDoesNotEraseNewerWake() {
        NativePushBridge.notifyFlutter(app, "pushMessage")
        idle()
        NativePushBridge.setUp(messenger)
        messenger.invoke("pushListenerReady")
        idle()
        NativePushBridge.notifyFlutter(app, "pushMessage")
        idle()
        assertEquals(1, messenger.sent.size)
        messenger.ack(0, true)
        idle()
        assertEquals(2, messenger.sent.size)
    }

    @Test fun restartReadsDurableWakesButDiscardsExpiredWake() {
        app.getSharedPreferences("pending_push_wakes", 0).edit()
            .putLong("pushMessage", System.currentTimeMillis())
            .putLong("friendRequest", System.currentTimeMillis() - 180_000)
            .commit()
        NativePushBridge.setUp(messenger, app)
        messenger.invoke("pushListenerReady")
        idle()
        assertEquals(listOf("pushMessage"), messenger.sent)
    }

    @Test fun stoppedListenerQueuesOnlyKnownWakeCategories() {
        NativePushBridge.setUp(messenger, app)
        messenger.invoke("pushListenerReady")
        messenger.invoke("pushListenerStopped")
        NativePushBridge.notifyFlutter(app, "unknown")
        NativePushBridge.notifyFlutter(app, "friendRequest")
        idle()
        assertTrue(messenger.sent.isEmpty())
        messenger.invoke("pushListenerReady")
        idle()
        assertEquals(listOf("friendRequest"), messenger.sent)
    }

    @Test fun lateAcknowledgementFromStoppedListenerCannotClearReplay() {
        NativePushBridge.setUp(messenger, app)
        messenger.invoke("pushListenerReady")
        NativePushBridge.notifyFlutter(app, "pushMessage")
        idle()
        messenger.invoke("pushListenerStopped")
        messenger.invoke("pushListenerReady")
        idle()
        assertEquals(2, messenger.sent.size)
        messenger.ack(0, true)
        idle()
        assertTrue(app.getSharedPreferences("pending_push_wakes", 0).contains("pushMessage"))
        messenger.ack(1, true)
        idle()
        assertEquals(false, app.getSharedPreferences("pending_push_wakes", 0).contains("pushMessage"))
    }
}
