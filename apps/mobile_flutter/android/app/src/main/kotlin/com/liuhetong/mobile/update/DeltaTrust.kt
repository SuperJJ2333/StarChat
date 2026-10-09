package com.liuhetong.mobile.update

import java.security.PublicKey
import java.security.Signature

object DeltaTrust {
    /** The caller supplies the installed APK certificate's public key, never metadata. */
    fun verify(payload: ByteArray, signature: ByteArray, installedKey: PublicKey): Boolean = try {
        payload.size <= 16384 && signature.size <= 1024 && installedKey.algorithm == "RSA" &&
            Signature.getInstance("SHA256withRSA").run { initVerify(installedKey); update(payload); verify(signature) }
    } catch (_: Exception) { false }
}

object DeltaPolicy {
    fun enoughSpace(available: Long, patch: Long, target: Long): Boolean =
        patch in 1..DeltaApplier.MAX_SIZE && target in 1..DeltaApplier.MAX_SIZE &&
            available >= patch + 2 * target + 32L * 1024 * 1024
    fun validTarget(expectedPackage: String, expectedBuild: Long, installedCertificates: Set<String>,
                    actualPackage: String, actualBuild: Long, actualCertificates: Set<String>, installedBuild: Long): Boolean =
        expectedPackage == actualPackage && expectedBuild == actualBuild && actualBuild > installedBuild &&
            installedCertificates.isNotEmpty() && installedCertificates == actualCertificates
    fun installAction(api: Int, canInstall: Boolean): String =
        if (api >= 26 && !canInstall) "permission_required" else "install"
}
