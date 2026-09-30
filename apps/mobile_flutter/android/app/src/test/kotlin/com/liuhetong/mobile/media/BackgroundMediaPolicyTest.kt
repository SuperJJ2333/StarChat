package com.liuhetong.mobile.media

import kotlin.test.assertFalse
import kotlin.test.assertTrue
import org.junit.Test

class BackgroundMediaPolicyTest {
    @Test fun onlyControlledHttpsPathsAndBoundedSizesAreAllowed() {
        assertTrue(BackgroundMediaPolicy.allows("https://matrix.test/_matrix/client/v1/media/download/test/id?allow_redirect=false", "https://matrix.test", "matrix", 1024, "Bearer test"))
        assertTrue(BackgroundMediaPolicy.allows("https://api.test/api/v1/moments/media/content/id", "https://api.test", "moments", 1024, null, "image"))
        assertFalse(BackgroundMediaPolicy.allows("https://other.test/_matrix/media/v3/download/test/id", "https://matrix.test", "matrix", 1024, "Bearer test"))
        assertFalse(BackgroundMediaPolicy.allows("http://matrix.test/_matrix/media/v3/download/test/id", "http://matrix.test", "matrix", 1024, null))
        assertFalse(BackgroundMediaPolicy.allows("https://api.test/api/v1/moments/media/content/id", "https://api.test", "moments", 1024, "Bearer secret"))
        assertFalse(BackgroundMediaPolicy.allows("https://api.test/other", "https://api.test", "moments", 1024, null))
        assertFalse(BackgroundMediaPolicy.allows("https://matrix.test/_matrix/media/v3/download/test/id", "https://matrix.test", "matrix", 67108865, null))
    }
}
