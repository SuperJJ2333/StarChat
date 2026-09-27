package com.liuhetong.mobile.call

import android.view.WindowManager
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import kotlin.test.assertEquals
import kotlin.test.assertTrue

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], application = android.app.Application::class, manifest = Config.NONE)
class LockScreenCallPresentationTest {
    @Test
    fun incomingCallWindowCannotDismissTheDeviceKeyguard() {
        CallManager.reset()
        CallManager.onIncoming("test-lock-call", "Incoming call", false)
        val controller = Robolectric.buildActivity(CallActivity::class.java).create()
        val activity = controller.get()
        try {
            val flags = activity.window.attributes.flags
            assertEquals(0, flags and WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD)
            assertTrue(flags and WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED != 0)
            assertTrue(flags and WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON != 0)
            assertEquals(CallManager.State.ringing, CallManager.state)
        } finally {
            controller.destroy()
            CallManager.reset()
        }
    }
}
