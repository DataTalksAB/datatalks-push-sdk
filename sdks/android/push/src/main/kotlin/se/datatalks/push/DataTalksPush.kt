package se.datatalks.push

import android.Manifest
import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.util.Log
import androidx.core.content.ContextCompat
import com.google.firebase.messaging.RemoteMessage
import se.datatalks.push.internal.AppKeys
import se.datatalks.push.internal.NotificationRenderer
import se.datatalks.push.internal.PendingIdentity
import se.datatalks.push.internal.PermissionRequests
import se.datatalks.push.internal.PushMessage
import se.datatalks.push.internal.PushRuntime
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Entry point of the Data Talks push SDK. Call [initialize] from `Application.onCreate`.
 *
 * Every call returns immediately. The work runs in the background, survives process death, and never throws for a
 * service error. Results are delivered to [DataTalksPushListener].
 */
object DataTalksPush {
    private const val TAG = "DataTalksPush"

    private val lifecycleRegistered = AtomicBoolean(false)

    /**
     * Starts the SDK with the app's publishable key. Registers the install on first launch and again whenever its FCM
     * token or notification permission changes. The key selects the host; a malformed key leaves the SDK off.
     */
    @JvmStatic
    @JvmOverloads
    fun initialize(context: Context, appKey: String, options: DataTalksPushOptions = DataTalksPushOptions()) {
        val application = context.applicationContext
        if (AppKeys.baseUrl(appKey) == null) {
            Log.e(TAG, "The app key is malformed: the SDK stays off. Copy the key from the portal.")
            return
        }

        val runtime = PushRuntime.get(application)
        if (lifecycleRegistered.compareAndSet(false, true)) {
            (application as? Application)?.registerActivityLifecycleCallbacks(ResumeWatcher(runtime))
        }

        runtime.execute { runtime.start(appKey, options.baseUrl, options.openLinks) }
    }

    /**
     * Sets the listener for opens, messages and identify results; set it from `Application.onCreate`. The most recent tap
     * that arrived while no listener was set (such as the one that launched the app) is delivered to the next listener.
     */
    @JvmStatic
    fun setListener(listener: DataTalksPushListener?) {
        PushRuntime.listener = listener
    }

    /**
     * Whether the app may show notifications. [DataTalksPermission.NOT_DETERMINED] occurs only on Android 13+, before
     * the app has asked through [requestPermission].
     */
    @JvmStatic
    fun permissionStatus(context: Context): DataTalksPermission = PushRuntime.get(context.applicationContext).facts.permissionStatus()

    /**
     * Requests the notification permission on Android 13+ from a transparent SDK activity shown over [activity]. Nothing
     * is shown before Android 13, when the permission is already granted, or when the app is not in the foreground.
     * [callback] receives the result, or the current status, on the main thread. The service learns of a change the
     * next time an activity resumes.
     */
    @JvmStatic
    @JvmOverloads
    fun requestPermission(activity: Activity, callback: DataTalksPermissionCallback? = null) {
        val runtime = PushRuntime.get(activity.applicationContext)
        val canPrompt = Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(activity, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        if (!canPrompt) {
            callback?.let { PermissionRequests.answerNow(it, runtime.facts.permissionStatus()) }
            return
        }

        PermissionRequests.ask(activity, callback)
    }

    /**
     * Links this install to the signed-in user. Pass the [identityToken] your backend signed for this user; an app that
     * requires verified identity refuses calls without one. The result goes to [DataTalksPushListener.onIdentityResult].
     * A refused identify is not retried: call it again at the next sign-in.
     *
     * Repeating the same external id and email (with or without a token, as before) on the same UTC day does not call
     * the service: the listener receives the earlier result, which says nothing about the token passed this time. A
     * token-only identify always calls the service.
     */
    @JvmStatic
    @JvmOverloads
    fun identify(externalId: String? = null, email: String? = null, identityToken: String? = null) {
        if (externalId.isNullOrEmpty() && email.isNullOrEmpty() && identityToken.isNullOrEmpty()) {
            Log.w(TAG, "identify needs an external id, an email or an identity token.")
            return
        }

        val runtime = started("identify") ?: return
        runtime.execute { runtime.identify(PendingIdentity.Identify(externalId, email, identityToken)) }
    }

    /** Unlinks this install from its user. The install stays registered. */
    @JvmStatic
    fun logout() {
        val runtime = started("logout") ?: return
        runtime.execute { runtime.identify(PendingIdentity.Logout) }
    }

    /** Records the user's in-app marketing choice on this device. Transactional pushes aren't affected. */
    @JvmStatic
    fun setMarketingOptIn(optIn: Boolean) {
        val runtime = started("setMarketingOptIn") ?: return
        runtime.execute { runtime.setMarketingOptIn(optIn) }
    }

    /**
     * Deletes this install on the service and everything the SDK keeps on the device. The SDK stays off until the
     * next [initialize], which starts a new install.
     */
    @JvmStatic
    fun deleteLocalData() {
        val runtime = started("deleteLocalData") ?: return
        runtime.execute { runtime.deleteLocalData() }
    }

    /**
     * For an app with its own `FirebaseMessagingService`: forward `onMessageReceived` here. Returns true for a Data Talks
     * message, which the SDK has rendered, and false for any other message, which the app handles itself.
     */
    @JvmStatic
    fun handleRemoteMessage(context: Context, message: RemoteMessage): Boolean {
        val push = PushMessage.from(message.data) ?: return false
        val application = context.applicationContext
        if (NotificationRenderer(application).show(push)) {
            // On this thread, not the SDK's executor: the process may end as soon as onMessageReceived returns.
            PushRuntime.get(application).pushShown(push.uid)
        }

        PushRuntime.notifyMessage(push.toPublic())
        return true
    }

    /**
     * For an app with its own `FirebaseMessagingService`: forward both `onNewToken` and `onRegistered` here. Firebase
     * calls only the one that matches the app's mode (token or FID).
     */
    @JvmStatic
    fun onNewRegistration(context: Context, value: String) {
        val runtime = PushRuntime.get(context.applicationContext)
        runtime.execute { runtime.onNewRegistration(value) }
    }

    private fun started(call: String): PushRuntime? {
        val runtime = PushRuntime.current()
        if (runtime == null) Log.e(TAG, "$call before initialize: nothing happened.")
        return runtime
    }

    private class ResumeWatcher(private val runtime: PushRuntime) : Application.ActivityLifecycleCallbacks {
        // The permission can only change while the app is in the background, and the daily refresh waits until the app
        // is used.
        override fun onActivityResumed(activity: Activity) = runtime.execute { runtime.syncIfDue() }

        // A tap on a notification that Android displayed itself launches the app with the push's keys, and FCM's, in the
        // intent extras. A recreated activity (savedInstanceState != null) carries the same tap again.
        override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {
            if (savedInstanceState != null) return
            val extras = activity.intent?.extras ?: return
            val uid = extras.getString("dt_uid") ?: return
            if (extras.getString("dt_v") == null || !extras.containsKey("google.message_id")) return
            runtime.systemNotificationOpened(uid, extras.getString("dt_link"))
        }

        override fun onActivityStarted(activity: Activity) = Unit

        override fun onActivityPaused(activity: Activity) = Unit

        override fun onActivityStopped(activity: Activity) = Unit

        override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit

        override fun onActivityDestroyed(activity: Activity) = Unit
    }
}
