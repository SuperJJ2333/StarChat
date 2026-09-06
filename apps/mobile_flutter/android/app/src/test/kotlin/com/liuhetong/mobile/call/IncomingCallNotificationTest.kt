package com.liuhetong.mobile.call

import android.Manifest
import android.app.Notification
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import kotlin.test.assertEquals
import kotlin.test.assertNotNull

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], application = android.app.Application::class, manifest = Config.NONE)
class IncomingCallNotificationTest {
    @Test
    fun deniedMediaPermissionsStillBuildActionableIncomingNotifications() {
        val app = RuntimeEnvironment.getApplication()
        shadowOf(app).denyPermissions(Manifest.permission.RECORD_AUDIO, Manifest.permission.CAMERA)
        for ((video, expected) in listOf(false to "语音通话", true to "畅聊视频来电")) {
            val notification = CallNotificationManager.buildIncoming(app, video)
            assertEquals(expected, notification.extras.getString(Notification.EXTRA_TITLE))
            assertNotNull(notification.fullScreenIntent)
            assertNotNull(notification.contentIntent)
        }
    }
}
