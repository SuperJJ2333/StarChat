package com.liuhetong.mobile.call

import com.liuhetong.mobile.MainActivity
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.shadows.ShadowSettings
import org.robolectric.shadows.ShadowWindowManagerImpl
import org.robolectric.shadow.api.Shadow
import android.content.Context
import android.content.ContextWrapper
import android.view.WindowManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.StandardMethodCodec
import java.nio.ByteBuffer
import org.robolectric.annotation.Config
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.test.assertEquals
import kotlin.test.assertSame

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], application = android.app.Application::class, manifest = Config.NONE)
class BackgroundCallPresentationTest {
    @Test
    fun deniedAnswerRestoresNativeRingingAndAllowsAnotherAnswer() {
        CallManager.reset()
        CallManager.appContext = null
        val uiEvents = mutableListOf<String>()
        val listener: (String) -> Unit = { uiEvents.add(it) }
        CallManager.addUiListener(listener)
        try {
            CallManager.onIncoming("test-call", "Test caller", true)
            CallManager.updateFromFlutter("requestingPermission", true)
            assertEquals(CallManager.State.answering, CallManager.state)
            shadowOf(android.os.Looper.getMainLooper()).idle()
            uiEvents.clear()
            CallManager.updateFromFlutter("ringing", true)
            shadowOf(android.os.Looper.getMainLooper()).idle()
            assertEquals(CallManager.State.ringing, CallManager.state)
            assertEquals(listOf(CallManager.eventIncoming), uiEvents)
            assertEquals("test-call", CallManager.callId)
            CallManager.updateFromFlutter("requestingPermission", true)
            assertEquals(CallManager.State.answering, CallManager.state)
        } finally {
            CallManager.removeUiListener(listener)
            CallManager.reset()
        }
    }

    private class Messenger : BinaryMessenger {
        val handlers = mutableMapOf<String, BinaryMessenger.BinaryMessageHandler>()
        override fun send(channel: String, message: ByteBuffer?) {}
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {}
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {
            if (handler == null) handlers.remove(channel) else handlers[channel] = handler
        }
        fun invoke(method: String, args: Any? = null): Any? {
            val buffer = StandardMethodCodec.INSTANCE.encodeMethodCall(MethodCall(method, args))
            buffer.flip()
            var result: Any? = null
            handlers.getValue("native_call").onMessage(buffer) { reply ->
                reply!!.flip()
                result = StandardMethodCodec.INSTANCE.decodeEnvelope(reply)
            }
            return result
        }
    }

    @Test
    fun foregroundCallWithoutPushCreatesRealOverlayWindowAndCleansItUp() {
        val context = RuntimeEnvironment.getApplication()
        CallManager.reset()
        CallManager.appContext = null // fresh process; no push/Telecom receiver ran
        ShadowSettings.setCanDrawOverlays(true)
        val messenger = Messenger()
        NativeCallBridge.setUp(ContextWrapper(context), messenger,
            NativeCallBridge.CallHandlers({}, {}, {}))
        assertSame(context, CallManager.appContext, "retain application, never activity context")
        messenger.invoke("reportCallState", mapOf("phase" to "connected", "video" to false))
        assertEquals(true, messenger.invoke("minimizeCallPresentation"))
        val started = shadowOf(context).nextStartedService
        assertEquals(CallOverlayService::class.java.name, started.component!!.className)
        val service = Robolectric.buildService(CallOverlayService::class.java).create().get()
        try {
            val windows = Shadow.extract<ShadowWindowManagerImpl>(
                service.getSystemService(Context.WINDOW_SERVICE) as WindowManager)
            service.onStartCommand(started, 0, 1)
            assertEquals(1, windows.views.size, "WindowManager must actually hold the system overlay")
            service.onStartCommand(started, 0, 2)
            assertEquals(1, windows.views.size, "repeated minimize must not duplicate windows")
            assertEquals(CallManager.State.active, CallManager.state)
            messenger.invoke("reportCallState", mapOf("phase" to "ended"))
            shadowOf(android.os.Looper.getMainLooper()).idle()
            assertTrue(shadowOf(service).isStoppedBySelf, "terminal state stops overlay service")
            service.onDestroy()
            assertTrue(windows.views.isEmpty())
        } finally {
            NativeCallBridge.teardown()
            CallManager.reset()
        }
    }

    @Test
    fun deniedOverlayPermissionPreservesActiveCallWithoutStartingAService() {
        val context = RuntimeEnvironment.getApplication()
        CallManager.reset()
        val messenger = Messenger()
        NativeCallBridge.setUp(context, messenger, NativeCallBridge.CallHandlers({}, {}, {}))
        ShadowSettings.setCanDrawOverlays(false)
        try {
            messenger.invoke("reportCallState", mapOf("phase" to "connected"))
            assertEquals(false, messenger.invoke("minimizeCallPresentation"))
            assertEquals(CallManager.State.active, CallManager.state)
            assertEquals(null, shadowOf(context).nextStartedService)
        } finally {
            NativeCallBridge.teardown()
            CallManager.reset()
        }
    }

    @Test
    fun repeatedRootBackIsConsumedWithoutFinishingActivity() {
        val activity = Robolectric.buildActivity(MainActivity::class.java).get()
        repeat(3) {
            assertTrue(activity.popSystemNavigator(), "root back must be handled as backgrounding")
            assertFalse(activity.isFinishing, "root back must preserve the Flutter activity")
        }
    }
}
