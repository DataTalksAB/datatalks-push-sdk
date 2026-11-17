package se.datatalks.push.internal

import android.content.Context
import android.content.pm.PackageManager
import android.util.Log
import com.google.android.gms.tasks.Tasks
import com.google.firebase.installations.FirebaseInstallations
import com.google.firebase.messaging.FirebaseMessaging
import java.util.concurrent.ExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

/**
 * Which FCM registration API the app uses. They are mutually exclusive: with the manifest flag on, `getToken()` fails,
 * and turning the flag on invalidates the app's token for every sender, so the SDK never sets it and only follows the
 * app. `firebase-messaging` before 25.1.0 ignores the flag, hence the reflective check for `register()`.
 */
internal object FcmMode {
    const val FLAG = "firebase_messaging_installation_id_enabled"

    private val hasRegister: Boolean by lazy {
        try {
            FirebaseMessaging::class.java.getMethod("register")
            true
        } catch (e: NoSuchMethodException) {
            false
        }
    }

    fun usesFid(context: Context): Boolean = hasRegister && flagIsOn(context)

    fun typeOf(context: Context): String = if (usesFid(context)) PushValue.TYPE_FID else PushValue.TYPE_TOKEN

    private fun flagIsOn(context: Context): Boolean = try {
        context.packageManager.getApplicationInfo(context.packageName, PackageManager.GET_META_DATA).metaData?.getBoolean(FLAG, false) ?: false
    } catch (e: PackageManager.NameNotFoundException) {
        false
    }
}

internal sealed interface PushValueLookup {
    data class Found(val value: PushValue) : PushValueLookup

    /** Firebase did not answer, which is normal when offline. */
    data object TryLater : PushValueLookup

    /** Firebase is not configured in the app: retrying will not help. */
    data object NotConfigured : PushValueLookup
}

internal fun interface PushValueSource {
    /** Blocking: call it off the main thread. */
    fun current(): PushValueLookup
}

/** Reads the current value from Firebase, which catches a token the app's own service didn't forward and a mode change. */
internal class FirebaseValues(private val context: Context, private val store: PushStore) : PushValueSource {
    override fun current(): PushValueLookup = try {
        PushValueLookup.Found(if (FcmMode.usesFid(context)) fid() else token())
    } catch (e: IllegalStateException) {
        Log.e(TAG, "Firebase isn't set up in this app, so it can't receive pushes. Add google-services.json.")
        PushValueLookup.NotConfigured
    } catch (e: ExecutionException) {
        Log.d(TAG, "Firebase gave no token: ${e.cause?.javaClass?.simpleName}")
        PushValueLookup.TryLater
    } catch (e: TimeoutException) {
        PushValueLookup.TryLater
    } catch (e: InterruptedException) {
        Thread.currentThread().interrupt()
        PushValueLookup.TryLater
    }

    // Deprecated in 25.1.0, but still the only API for an app without FID registration.
    @Suppress("DEPRECATION")
    private fun token(): PushValue =
        PushValue(Tasks.await(FirebaseMessaging.getInstance().token, TIMEOUT_SECONDS, TimeUnit.SECONDS), PushValue.TYPE_TOKEN)

    private fun fid(): PushValue {
        // Once per install: each call fires onRegistered again, and auto-init keeps the registration fresh afterwards.
        if (store.pushValue?.type != PushValue.TYPE_FID) {
            Tasks.await(FirebaseMessaging.getInstance().register(), TIMEOUT_SECONDS, TimeUnit.SECONDS)
        }

        return PushValue(Tasks.await(FirebaseInstallations.getInstance().id, TIMEOUT_SECONDS, TimeUnit.SECONDS), PushValue.TYPE_FID)
    }

    private companion object {
        const val TAG = "DataTalksPush"
        const val TIMEOUT_SECONDS = 30L
    }
}
