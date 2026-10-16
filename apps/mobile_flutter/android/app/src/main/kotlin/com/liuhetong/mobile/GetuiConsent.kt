package com.liuhetong.mobile

import android.content.Context
import com.igexin.sdk.PushManager

/** Shares the existing Flutter legacy preference; it never infers or writes consent. */
internal object GetuiConsent {
    fun accepted(context: Context): Boolean = try {
        context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            .getBoolean("flutter.privacy.agreement_accepted.v1", false)
    } catch (_: Exception) {
        false
    }

    fun preInitialize(context: Context): Boolean = whenAccepted(context) {
        PushManager.getInstance().preInit(context.applicationContext)
    }

    fun initialize(context: Context): Boolean = whenAccepted(context) {
        // First consent can happen after Application.onCreate skipped preparation.
        // Getui documents repeated preInit calls as safe.
        val manager = PushManager.getInstance()
        manager.preInit(context.applicationContext)
        manager.initialize(context.applicationContext)
    }

    private inline fun whenAccepted(context: Context, action: () -> Unit): Boolean {
        if (!accepted(context)) return false
        return try {
            action()
            true
        } catch (_: Exception) {
            false
        } catch (_: LinkageError) {
            // An unavailable optional SDK must not crash the chat process.
            false
        }
    }
}
