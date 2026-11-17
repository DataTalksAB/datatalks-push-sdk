package se.datatalks.push.internal

import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.ApplicationInfo
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.annotation.VisibleForTesting
import org.json.JSONObject
import se.datatalks.push.DataTalksIdentityResult
import se.datatalks.push.DataTalksMessage
import se.datatalks.push.DataTalksPushListener
import java.util.concurrent.Executor
import java.util.concurrent.Executors

/** Per-process SDK state, created by the first call that needs it (possibly a push with no activity running). */
@SuppressLint("StaticFieldLeak") // Holds only the application context, which lives as long as the process.
internal class PushRuntime private constructor(private val context: Context) {
    val store = PushStore(context)
    val facts = DeviceFacts(context, store)
    val sync = PushSync(store, FirebaseValues(context, store), facts, ::notifyIdentity)

    private val background: Executor = Executors.newSingleThreadExecutor { task -> Thread(task, "DataTalksPush") }

    /** Runs [work] on the SDK's single background thread: storage and Keystore stay off the main thread, calls stay in order. */
    fun execute(work: () -> Unit) = background.execute {
        try {
            work()
        } catch (e: Exception) {
            // A misbehaving Keystore or storage must not crash the host app.
            Log.e(TAG, "A background step failed: ${e.javaClass.simpleName}")
        }
    }

    fun start(appKey: String, baseUrl: String?, openLinks: Boolean) {
        if (store.openLinks != openLinks) store.openLinks = openLinks
        if (store.appKey != appKey || store.baseUrl != baseUrl) {
            store.replaceAppKey(appKey)
            store.baseUrl = baseUrl
            sync.stopped = false
        }

        syncIfDue()
    }

    fun syncIfDue() {
        if (sync.isDue()) SyncScheduler.whenIdle(context)
    }

    fun onNewRegistration(value: String) {
        val changed = store.updatePushValue(PushValue(value, FcmMode.typeOf(context)))
        if (changed && store.appKey != null) SyncScheduler.now(context)
    }

    fun identify(identity: PendingIdentity) {
        val isDebuggable = context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0
        if (isDebuggable && store.requireVerifiedIdentity && identity is PendingIdentity.Identify && identity.identityToken == null) {
            Log.w(TAG, "This app requires verified identity: identify without an identity token will be refused.")
        }

        // Already accepted today for this install: skip the call and repeat the earlier result, so an app that identifies
        // at every start makes at most one call a day.
        store.queueIdentity(identity, sync.today())?.let { verified ->
            notifyIdentity(DataTalksIdentityResult(verified))
            return
        }

        SyncScheduler.now(context)
    }

    fun setMarketingOptIn(optIn: Boolean) {
        store.pendingOptIn = optIn
        SyncScheduler.now(context)
    }

    fun deleteLocalData() {
        val key = store.appKey
        val installId = store.installId
        val secret = store.deviceSecret
        val pending = if (key != null && installId != null && secret != null) {
            PendingDelete(key, store.baseUrl, installId, secret)
        } else {
            store.pendingDelete
        }

        store.wipe()
        if (pending != null) {
            store.pendingDelete = pending
            SyncScheduler.now(context)
        }
    }

    /** A tap on a push the SDK displayed: an open, plus a click when the push has a link (whether the SDK or the app opens it). */
    fun notificationOpened(uid: String?, deepLink: String?, data: JSONObject?) {
        execute { uid?.let { queueOpen(it, deepLink) } }
        notifyOpened(deepLink, data)
    }

    /** Queues a delivery for a displayed push. Runs on the caller's thread, since the process may end once it returns. */
    fun pushShown(uid: String?) {
        uid ?: return
        try {
            store.queueEvent(PushEvent.DELIVERY, uid, System.currentTimeMillis())
            SyncScheduler.whenIdle(context)
        } catch (e: Exception) {
            Log.e(TAG, "A delivery couldn't be kept: ${e.javaClass.simpleName}")
        }
    }

    /**
     * A tap on a push that Android displayed itself (a device registered by the customer's backend, app in the
     * background), which launches the app with the push's keys in its intent. The service drops repeated opens, so
     * reading the same intent twice is harmless.
     */
    fun systemNotificationOpened(uid: String, link: String?) = execute { queueOpen(uid, link) }

    private fun queueOpen(uid: String, link: String?) {
        val now = System.currentTimeMillis()
        store.queueEvent(PushEvent.OPEN, uid, now)
        if (!link.isNullOrEmpty()) store.queueEvent(PushEvent.CLICK, uid, now, link)
        SyncScheduler.whenIdle(context)
    }

    private class HeldOpen(val deepLink: String?, val data: JSONObject?)

    companion object {
        private const val TAG = "DataTalksPush"

        @Volatile
        private var instance: PushRuntime? = null

        private val listenerLock = Any()
        private var currentListener: DataTalksPushListener? = null

        // A tap that launched the app can arrive before a wrapper sets its listener; the most recent one is held for it.
        private var heldOpen: HeldOpen? = null

        var listener: DataTalksPushListener?
            get() = synchronized(listenerLock) { currentListener }
            set(value) {
                val held = synchronized(listenerLock) {
                    currentListener = value
                    val waiting = if (value == null) null else heldOpen
                    if (value != null) heldOpen = null
                    waiting
                }
                if (value != null && held != null) onMain { value.onNotificationOpened(held.deepLink, held.data) }
            }

        fun get(context: Context): PushRuntime = instance ?: synchronized(this) {
            instance ?: PushRuntime(context.applicationContext).also { instance = it }
        }

        fun current(): PushRuntime? = instance

        @VisibleForTesting
        fun resetForTests() {
            instance = null
            synchronized(listenerLock) { heldOpen = null }
            PermissionRequests.resetForTests()
        }

        fun notifyMessage(message: DataTalksMessage) = onMain { listener?.onMessageReceived(message) }

        private fun notifyOpened(deepLink: String?, data: JSONObject?) = onMain {
            val target = synchronized(listenerLock) {
                if (currentListener == null) heldOpen = HeldOpen(deepLink, data)
                currentListener
            }
            target?.onNotificationOpened(deepLink, data)
        }

        private fun notifyIdentity(result: DataTalksIdentityResult) = onMain { listener?.onIdentityResult(result) }

        private fun onMain(call: () -> Unit) {
            Handler(Looper.getMainLooper()).post(call)
        }
    }
}
