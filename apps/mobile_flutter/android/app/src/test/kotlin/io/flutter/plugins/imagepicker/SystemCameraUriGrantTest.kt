package io.flutter.plugins.imagepicker

import android.app.Activity
import android.Manifest
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.content.pm.ResolveInfo
import android.net.Uri
import android.provider.MediaStore
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import javax.xml.parsers.DocumentBuilderFactory
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * Runs the pinned plugin, not a reimplementation of its grant loop. Package
 * visibility is modeled explicitly: only manifest-declared actions resolve.
 * Robolectric does not emulate Android's package visibility policy or Honor OS.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = android.app.Application::class, manifest = Config.NONE)
class SystemCameraUriGrantTest {
    class CameraActivity : Activity() {
        data class Grant(val target: String, val uri: Uri, val flags: Int)
        val grants = mutableListOf<Grant>()
        var launched: Intent? = null
        var grantsAtLaunch = 0
        var unavailable = false
        var permissionRequest: Int? = null
        var completion: Result<List<String>>? = null

        override fun grantUriPermission(toPackage: String, uri: Uri, modeFlags: Int) {
            grants.add(Grant(toPackage, uri, modeFlags))
        }

        override fun startActivityForResult(intent: Intent, requestCode: Int) {
            if (unavailable) throw ActivityNotFoundException()
            grantsAtLaunch = grants.size
            launched = intent
        }
    }

    private fun declaredActions(): Set<String> {
        val document = DocumentBuilderFactory.newInstance().apply {
            isNamespaceAware = true
        }.newDocumentBuilder().parse(File("src/main/AndroidManifest.xml"))
        val queries = document.getElementsByTagName("queries").item(0)
        val result = mutableSetOf<String>()
        val intents = queries.childNodes
        for (i in 0 until intents.length) {
            val intent = intents.item(i)
            if (intent.nodeName != "intent") continue
            val children = intent.childNodes
            for (j in 0 until children.length) {
                val child = children.item(j)
                if (child.nodeName == "action") {
                    result.add(child.attributes.getNamedItemNS(
                        "http://schemas.android.com/apk/res/android", "name").nodeValue)
                }
            }
        }
        return result
    }

    private fun capture(
        action: String,
        visibleActions: Set<String>,
        permissionGranted: Boolean = true,
        unavailable: Boolean = false,
        resultCode: Int? = null,
        afterLaunch: ((ImagePickerDelegate, CameraActivity) -> Unit)? = null,
    ): CameraActivity {
        val controller = Robolectric.buildActivity(CameraActivity::class.java).setup()
        val activity = controller.get()
        activity.unavailable = unavailable
        val executor = Executors.newSingleThreadExecutor()
        try {
            if (action in visibleActions) {
                shadowOf(activity.packageManager).addResolveInfoForIntentNoDefaults(
                    Intent(action), ResolveInfo().apply {
                        isDefault = true
                        match = Int.MAX_VALUE
                        activityInfo = ActivityInfo().apply {
                            packageName = "test.oem.camera"
                            name = "test.oem.camera.CaptureActivity"
                            exported = true
                        }
                    })
            }
            val delegate = ImagePickerDelegate(
                activity, ImageResizer(activity, ExifDataCopier()), null, null, null,
                ImagePickerCache(activity),
                object : ImagePickerDelegate.PermissionManager {
                    override fun isPermissionGranted(permissionName: String) = permissionGranted
                    override fun askForPermission(permissionName: String, requestCode: Int) {
                        assertEquals(Manifest.permission.CAMERA, permissionName)
                        activity.permissionRequest = requestCode
                    }
                    override fun needRequestCameraPermission() = true
                },
                object : ImagePickerDelegate.FileUriResolver {
                    private var createdFile: File? = null
                    override fun resolveFileProviderUriForFile(name: String, file: File): Uri {
                        assertEquals("${activity.packageName}.flutter.image_provider", name)
                        assertTrue(file.exists())
                        createdFile = file
                        return Uri.parse("content://$name/${file.name}")
                    }
                    override fun getFullImagePath(uri: Uri, listener: ImagePickerDelegate.OnPathReadyListener) {
                        // Native cache paths are Windows paths in this JVM test;
                        // Android's media scanner resolves the created file on-device.
                        listener.onPathReady(assertNotNull(createdFile).absolutePath.replace('\\', '/'))
                    }
                }, FileUtils(), executor)
            if (action == MediaStore.ACTION_IMAGE_CAPTURE) {
                delegate.takeImageWithCamera(ImageSelectionOptions(quality = 92)) { activity.completion = it }
            } else {
                delegate.takeVideoWithCamera(VideoSelectionOptions()) { activity.completion = it }
            }
            afterLaunch?.invoke(delegate, activity)
            if (resultCode != null) {
                val request = if (action == MediaStore.ACTION_IMAGE_CAPTURE)
                    ImagePickerDelegate.REQUEST_CODE_TAKE_IMAGE_WITH_CAMERA
                else ImagePickerDelegate.REQUEST_CODE_TAKE_VIDEO_WITH_CAMERA
                assertTrue(delegate.onActivityResult(request, resultCode, null))
                executor.submit { }.get(5, TimeUnit.SECONDS)
            }
            return activity
        } finally {
            executor.shutdownNow()
            controller.destroy()
        }
    }

    private fun assertOutputGranted(action: String) {
        val activity = capture(action, declaredActions())
        val intent = assertNotNull(activity.launched)
        assertEquals(action, intent.action)
        val output = assertNotNull(intent.getParcelableExtra(MediaStore.EXTRA_OUTPUT, Uri::class.java))
        assertEquals("content", output.scheme)
        val grant = activity.grants.singleOrNull()
        assertNotNull(grant, "Restricted visibility must expose the camera to the pinned plugin grant loop")
        assertEquals("test.oem.camera", grant.target)
        assertEquals(output, grant.uri)
        assertEquals(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION, grant.flags)
        assertEquals(1, activity.grantsAtLaunch, "Grant must precede system camera launch")
    }

    @Test fun photoOutputIsGrantedBeforeLaunchingSystemCamera() =
        assertOutputGranted(MediaStore.ACTION_IMAGE_CAPTURE)

    @Test fun videoOutputIsGrantedBeforeLaunchingSystemCamera() =
        assertOutputGranted(MediaStore.ACTION_VIDEO_CAPTURE)

    @Test fun undeclaredCameraRemainsLaunchableButReceivesNoExplicitOutputGrant() {
        for (action in listOf(MediaStore.ACTION_IMAGE_CAPTURE, MediaStore.ACTION_VIDEO_CAPTURE)) {
            val activity = capture(action, emptySet())
            assertNotNull(activity.launched)
            assertTrue(activity.grants.isEmpty())
        }
    }

    @Test fun deniedCameraPermissionFailsBothCapturesWithoutLaunching() {
        for (action in listOf(MediaStore.ACTION_IMAGE_CAPTURE, MediaStore.ACTION_VIDEO_CAPTURE)) {
            val activity = capture(action, declaredActions(), permissionGranted = false) { delegate, camera ->
                assertTrue(camera.grants.isEmpty())
                assertNull(camera.launched)
                val request = assertNotNull(camera.permissionRequest)
                assertTrue(delegate.onRequestPermissionsResult(request,
                    arrayOf(Manifest.permission.CAMERA), intArrayOf(PackageManager.PERMISSION_DENIED)))
            }
            assertEquals("camera_access_denied",
                (activity.completion?.exceptionOrNull() as FlutterError).code)
        }
    }

    @Test fun unavailableCameraFailsBothCapturesWithoutClaimingCancellation() {
        for (action in listOf(MediaStore.ACTION_IMAGE_CAPTURE, MediaStore.ACTION_VIDEO_CAPTURE)) {
            val activity = capture(action, declaredActions(), unavailable = true)
            assertEquals("no_available_camera",
                (activity.completion?.exceptionOrNull() as FlutterError).code)
        }
    }

    @Test fun cancelledCaptureReturnsEmptySuccessForBothMediaTypes() {
        for (action in listOf(MediaStore.ACTION_IMAGE_CAPTURE, MediaStore.ACTION_VIDEO_CAPTURE)) {
            val activity = capture(action, declaredActions(), resultCode = Activity.RESULT_CANCELED)
            assertEquals(emptyList(), assertNotNull(activity.completion).getOrThrow())
        }
    }

    @Test fun successfulCaptureReturnsTemporaryLocalFileForBothMediaTypes() {
        for (action in listOf(MediaStore.ACTION_IMAGE_CAPTURE, MediaStore.ACTION_VIDEO_CAPTURE)) {
            val activity = capture(action, declaredActions(), resultCode = Activity.RESULT_OK)
            val path = assertNotNull(activity.completion).getOrThrow().single()
            assertTrue(File(path).exists())
            assertTrue(path.endsWith(if (action == MediaStore.ACTION_IMAGE_CAPTURE) ".jpg" else ".mp4"))
        }
    }

    @Test fun duplicateCaptureReportsBusyWhileOriginalCanStillCancel() {
        for (action in listOf(MediaStore.ACTION_IMAGE_CAPTURE, MediaStore.ACTION_VIDEO_CAPTURE)) {
            val activity = capture(action, declaredActions(), resultCode = Activity.RESULT_CANCELED) { delegate, _ ->
                var duplicate: Result<List<String>>? = null
                if (action == MediaStore.ACTION_IMAGE_CAPTURE) {
                    delegate.takeImageWithCamera(ImageSelectionOptions(quality = 92)) { duplicate = it }
                } else {
                    delegate.takeVideoWithCamera(VideoSelectionOptions()) { duplicate = it }
                }
                assertEquals("already_active", (duplicate?.exceptionOrNull() as FlutterError).code)
            }
            assertEquals(emptyList(), assertNotNull(activity.completion).getOrThrow())
            assertEquals(1, activity.grantsAtLaunch)
        }
    }
}
