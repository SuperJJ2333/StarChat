package com.liuhetong.mobile

import android.app.Application
import android.content.Context
import com.igexin.sdk.PushManager
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.Implementation
import org.robolectric.annotation.Implements
import org.robolectric.util.ReflectionHelpers
import org.robolectric.util.ReflectionHelpers.ClassParameter

/** Spy only the external SDK effects; real Application and Android prefs remain in use. */
@Implements(value = PushManager::class, isInAndroidSdk = false)
class ConsentPushManagerShadow {
    companion object {
        val calls = mutableListOf<String>()
        var failPreparation = false
    }
    @Implementation fun preInit(context: Context) {
        calls.add("preInit")
        if (failPreparation) throw IllegalStateException("synthetic SDK failure")
    }
    @Implementation fun initialize(context: Context) { calls.add("initialize") }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], application = Application::class, manifest = Config.NONE,
    shadows = [ConsentPushManagerShadow::class])
class GetuiConsentStartupTest {
    private val prefs get() = RuntimeEnvironment.getApplication()
        .getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
    private val key = "flutter.privacy.agreement_accepted.v1"

    @Before fun reset() {
        prefs.edit().clear().commit()
        ConsentPushManagerShadow.calls.clear()
        ConsentPushManagerShadow.failPreparation = false
    }

    private fun startApplication() {
        val app = ChatFlowApplication()
        ReflectionHelpers.callInstanceMethod<Void>(app, "attach",
            ClassParameter.from(Context::class.java, RuntimeEnvironment.getApplication()))
        app.onCreate()
    }

    @Test fun `first launch does not initialize push before consent`() {
        startApplication()
        assertEquals(emptyList(), ConsentPushManagerShadow.calls)
    }

    @Test fun `explicit false consent does not initialize push`() {
        prefs.edit().putBoolean(key, false).commit()
        startApplication()
        assertEquals(emptyList(), ConsentPushManagerShadow.calls)
    }

    @Test fun `accepted existing user retains background preparation`() {
        prefs.edit().putBoolean(key, true).commit()
        startApplication()
        assertEquals(listOf("preInit"), ConsentPushManagerShadow.calls)
    }

    @Test fun `native initialize refuses missing and false consent`() {
        val context = RuntimeEnvironment.getApplication()
        assertFalse(GetuiConsent.initialize(context))
        prefs.edit().putBoolean(key, false).commit()
        assertFalse(GetuiConsent.initialize(context))
        assertEquals(emptyList(), ConsentPushManagerShadow.calls)
    }

    @Test fun `first consent after cold start prepares then registers CID`() {
        startApplication()
        prefs.edit().putBoolean(key, true).commit()
        assertTrue(GetuiConsent.initialize(RuntimeEnvironment.getApplication()))
        assertEquals(listOf("preInit", "initialize"), ConsentPushManagerShadow.calls)
    }

    @Test fun `malformed persisted consent fails closed without crashing startup`() {
        prefs.edit().putString(key, "true").commit()
        startApplication()
        assertFalse(GetuiConsent.initialize(RuntimeEnvironment.getApplication()))
        assertEquals(emptyList(), ConsentPushManagerShadow.calls)
    }

    @Test fun `SDK preparation failure prevents registration but allows retry`() {
        prefs.edit().putBoolean(key, true).commit()
        ConsentPushManagerShadow.failPreparation = true
        assertFalse(GetuiConsent.initialize(RuntimeEnvironment.getApplication()))
        assertEquals(listOf("preInit"), ConsentPushManagerShadow.calls)
        ConsentPushManagerShadow.failPreparation = false
        assertTrue(GetuiConsent.initialize(RuntimeEnvironment.getApplication()))
        assertEquals(listOf("preInit", "preInit", "initialize"), ConsentPushManagerShadow.calls)
    }
}
