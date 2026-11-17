package se.datatalks.push.internal

import android.Manifest
import android.app.Activity
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.annotation.VisibleForTesting
import se.datatalks.push.DataTalksPermission
import se.datatalks.push.DataTalksPermissionCallback

/**
 * Requests the notification permission. Only the requesting activity receives the result, hence this transparent
 * activity: the system prompt shows over the app's screen, and the activity finishes once answered.
 */
internal class PermissionRequestActivity : Activity() {
    private var answered = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            answer(null)
            return
        }

        // After a configuration change the request is still showing, and its result goes to the new instance.
        if (savedInstanceState == null) {
            // Only a shown prompt counts as asked: from then on a disabled permission reads DENIED, not NOT_DETERMINED.
            val runtime = PushRuntime.get(applicationContext)
            runtime.execute { runtime.store.permissionAsked = true }
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_CODE)
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        if (requestCode != REQUEST_CODE) return
        // An empty result means the request was interrupted: report the current status instead.
        val permission = when {
            grantResults.isEmpty() -> null
            grantResults[0] == PackageManager.PERMISSION_GRANTED -> DataTalksPermission.AUTHORIZED
            else -> DataTalksPermission.DENIED
        }
        answer(permission)
    }

    override fun onDestroy() {
        super.onDestroy()
        // Finished without a result: answer the callers with the current status so the next request can start.
        if (!answered && isFinishing) PermissionRequests.answer(applicationContext, null)
    }

    private fun answer(permission: DataTalksPermission?) {
        answered = true
        PermissionRequests.answer(applicationContext, permission)
        finish()
        @Suppress("DEPRECATION")
        overridePendingTransition(0, 0)
    }

    private companion object {
        const val REQUEST_CODE = 0x4454
    }
}

/** The callbacks waiting for the single request in progress. */
internal object PermissionRequests {
    private val lock = Any()
    private val waiting = mutableListOf<DataTalksPermissionCallback>()
    private var asking = false

    fun ask(activity: Activity, callback: DataTalksPermissionCallback?) {
        val start = synchronized(lock) {
            callback?.let(waiting::add)
            val idle = !asking
            asking = true
            idle
        }
        if (!start) return

        // Android silently drops an activity start from a background app. No result would ever arrive and later requests
        // would wait behind this one, so answer with the current status instead.
        val context = activity.applicationContext
        if (!onScreen()) {
            Handler(Looper.getMainLooper()).post { answer(context, null) }
            return
        }

        try {
            activity.startActivity(Intent(activity, PermissionRequestActivity::class.java))
        } catch (e: RuntimeException) {
            Log.w(TAG, "The permission prompt couldn't start: ${e.javaClass.simpleName}")
            Handler(Looper.getMainLooper()).post { answer(context, null) }
            return
        }
        @Suppress("DEPRECATION")
        activity.overridePendingTransition(0, 0)
    }

    /** Main thread only. With a null [permission], the callers receive the current status. */
    fun answer(context: Context, permission: DataTalksPermission?) {
        val callbacks = synchronized(lock) {
            asking = false
            waiting.toList().also { waiting.clear() }
        }
        if (callbacks.isEmpty()) return

        val result = permission ?: PushRuntime.get(context).facts.permissionStatus()
        callbacks.forEach { it.onResult(result) }
    }

    /** Answers on the main thread after the caller returns, as a real request would. */
    fun answerNow(callback: DataTalksPermissionCallback, permission: DataTalksPermission) {
        Handler(Looper.getMainLooper()).post { callback.onResult(permission) }
    }

    @VisibleForTesting
    fun resetForTests() = synchronized(lock) {
        asking = false
        waiting.clear()
    }

    /**
     * Whether the app is in the foreground, which starting an activity requires. An activity being launched counts; a
     * foreground service alone does not.
     */
    private fun onScreen(): Boolean {
        val process = ActivityManager.RunningAppProcessInfo()
        ActivityManager.getMyMemoryState(process)
        return process.importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND
    }

    private const val TAG = "DataTalksPush"
}
