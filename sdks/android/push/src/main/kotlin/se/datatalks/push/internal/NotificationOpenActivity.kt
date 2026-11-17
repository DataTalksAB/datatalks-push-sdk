package se.datatalks.push.internal

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.util.Log

/**
 * Target of a notification tap. An activity rather than a receiver, because from Android 12 a receiver cannot start an
 * activity after a notification tap (trampoline restriction). No UI; it finishes immediately.
 */
internal class NotificationOpenActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val link = intent.getStringExtra(EXTRA_LINK)
        val runtime = PushRuntime.get(applicationContext)
        runtime.notificationOpened(intent.getStringExtra(EXTRA_UID), link, PushMessage.parseData(intent.getStringExtra(EXTRA_DATA)))

        // With openLinks off, the app routes the link itself from onNotificationOpened.
        if (link == null || !runtime.store.openLinks || !openLink(link)) openLauncher()
        finish()
    }

    private fun openLink(link: String): Boolean {
        val uri = Uri.parse(link)
        val intent = Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        // https links go through the system so verified App Links resolve; any other scheme is limited to this app.
        if (!uri.scheme.equals("https", ignoreCase = true)) intent.setPackage(packageName)
        return try {
            startActivity(intent)
            true
        } catch (e: ActivityNotFoundException) {
            Log.w(TAG, "Nothing handles a push's link, so the app opens instead.")
            false
        }
    }

    private fun openLauncher() {
        val launcher = packageManager.getLaunchIntentForPackage(packageName) ?: return
        startActivity(launcher.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED))
    }

    companion object {
        private const val TAG = "DataTalksPush"
        const val EXTRA_UID = "se.datatalks.push.uid"
        const val EXTRA_LINK = "se.datatalks.push.link"
        const val EXTRA_DATA = "se.datatalks.push.data"
    }
}
