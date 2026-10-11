package com.liuhetong.mobile.media;

import android.system.ErrnoException;
import org.robolectric.annotation.Implementation;
import org.robolectric.annotation.Implements;
import org.robolectric.shadows.ShadowPosix;

/** API 24/25 uses Posix; preserve other framework shadows while fixing lstat. */
@Implements(className = "libcore.io.Posix", isInAndroidSdk = false, maxSdk = 25)
public class NoFollowPosix extends ShadowPosix {
    @Implementation
    protected static Object lstat(String path) throws ErrnoException {
        return MediaStoragePolicyTestKt.inspectNoFollow(path);
    }
}
