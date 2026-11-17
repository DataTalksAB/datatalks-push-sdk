package se.datatalks.push.internal

import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.ExecutionException
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

/**
 * Renders a data-only push, on the messaging service's background thread. Firebase lowers the priority of an app whose
 * high-priority messages show nothing, so a push is skipped only when it has neither title nor body.
 *
 * `dt_color` overrides the manifest's colour and `dt_large_icon` adds a large icon. The small icon cannot come with the
 * push: Android draws it from a drawable in the app.
 */
internal class NotificationRenderer(
    private val context: Context,
    private val loadLargeIcon: (String) -> Bitmap? = ::downloadLargeIcon,
    private val loadImage: (String) -> Bitmap? = ::downloadImage,
) {
    private val settings: Bundle = try {
        context.packageManager.getApplicationInfo(context.packageName, PackageManager.GET_META_DATA).metaData ?: Bundle.EMPTY
    } catch (e: PackageManager.NameNotFoundException) {
        Bundle.EMPTY
    }

    /**
     * Shows the push. Returns true when it is visible, that is when notifications are enabled for the app and for the
     * channel; only then does the push count as delivered.
     */
    fun show(message: PushMessage): Boolean {
        if (message.title.isNullOrEmpty() && message.body.isNullOrEmpty()) {
            Log.w(TAG, "A push has no title and no body, so nothing was shown.")
            return false
        }

        val tag = message.tag ?: DEFAULT_TAG
        val channel = channelFor(message)
        val builder = NotificationCompat.Builder(context, channel)
            .setSmallIcon(smallIcon())
            .setContentTitle(message.title)
            .setContentText(message.body)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(openIntent(message, tag))

        (pushColor(message.color) ?: color())?.let(builder::setColor)
        applySound(builder, message.sound)

        // The two downloads run in parallel: each can take up to twice IMAGE_TIMEOUT_MILLIS (connect and read), and the
        // messaging service allows about 20 seconds per message.
        val largeIcon = message.largeIcon?.let { url -> inBackground { loadLargeIcon(url) } }
        val picture = message.image?.let(loadImage)
        largeIcon?.let { await(it) }?.let { builder.setLargeIcon(it) }
        if (picture != null) {
            builder.setStyle(NotificationCompat.BigPictureStyle().bigPicture(picture))
        } else if (message.body != null) {
            builder.setStyle(NotificationCompat.BigTextStyle().bigText(message.body))
        }

        val manager = NotificationManagerCompat.from(context)
        try {
            manager.notify(tag, NOTIFICATION_ID, builder.build())
        } catch (e: SecurityException) {
            Log.w(TAG, "The notification permission is missing, so a push wasn't shown.")
            return false
        }

        // Before Android 13 a disabled notification is dropped without an error, so check the settings explicitly.
        val channelOff = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && manager.getNotificationChannel(channel)?.importance == NotificationManager.IMPORTANCE_NONE
        return manager.areNotificationsEnabled() && !channelOff
    }

    private fun channelFor(message: PushMessage): String {
        val manager = NotificationManagerCompat.from(context)
        // A notification posted to a channel that doesn't exist is dropped, so fall back to the default channel.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val requested = message.channel
            if (requested != null && manager.getNotificationChannel(requested) != null) return requested
            if (manager.getNotificationChannel(DEFAULT_CHANNEL) == null) {
                val name = settings.getString(CHANNEL_NAME_KEY) ?: context.getString(se.datatalks.push.R.string.datatalks_push_default_channel_name)
                manager.createNotificationChannel(NotificationChannel(DEFAULT_CHANNEL, name, NotificationManager.IMPORTANCE_HIGH))
            }
        }

        return DEFAULT_CHANNEL
    }

    private fun smallIcon(): Int {
        val icon = settings.getInt(ICON_KEY).takeIf { it != 0 } ?: settings.getInt(FIREBASE_ICON_KEY)
        return icon.takeIf { it != 0 } ?: context.applicationInfo.icon.takeIf { it != 0 } ?: android.R.drawable.ic_dialog_info
    }

    private fun color(): Int? {
        val color = settings.getInt(COLOR_KEY).takeIf { it != 0 } ?: settings.getInt(FIREBASE_COLOR_KEY)
        return color.takeIf { it != 0 }?.let { ContextCompat.getColor(context, it) }
    }

    /** The push's `dt_color` (`#RRGGBB`), or null when it is absent or in another format. */
    private fun pushColor(value: String?): Int? =
        if (value != null && COLOR_PATTERN.matches(value)) Color.parseColor(value) else null

    private fun <T> inBackground(load: () -> T): FutureTask<T> =
        FutureTask(load).also { Thread(it, "DataTalksPushLargeIcon").start() }

    /** Null when the download failed or timed out; the push is then shown without it. */
    private fun <T> await(task: FutureTask<T>): T? = try {
        task.get(LARGE_ICON_WAIT_MILLIS, TimeUnit.MILLISECONDS)
    } catch (e: InterruptedException) {
        Thread.currentThread().interrupt()
        task.cancel(true)
        null
    } catch (e: ExecutionException) {
        null
    } catch (e: TimeoutException) {
        task.cancel(true)
        null
    }

    // From Android 8 the sound belongs to the channel and a push can't change it. The payload names a raw resource, hence the lookup by name.
    @SuppressLint("DiscouragedApi")
    private fun applySound(builder: NotificationCompat.Builder, sound: String?) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) return
        if (sound == null || sound == "default") {
            builder.setDefaults(NotificationCompat.DEFAULT_ALL)
            return
        }

        val resource = context.resources.getIdentifier(sound, "raw", context.packageName)
        if (resource != 0) {
            builder.setSound(Uri.parse("${ContentResolver.SCHEME_ANDROID_RESOURCE}://${context.packageName}/$resource"))
        }
    }

    private fun openIntent(message: PushMessage, tag: String): PendingIntent {
        val intent = Intent(context, NotificationOpenActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            .putExtra(NotificationOpenActivity.EXTRA_UID, message.uid)
            .putExtra(NotificationOpenActivity.EXTRA_LINK, message.link)
            .putExtra(NotificationOpenActivity.EXTRA_DATA, message.dataText)
        return PendingIntent.getActivity(context, tag.hashCode(), intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    private companion object {
        const val TAG = "DataTalksPush"
        const val DEFAULT_CHANNEL = "datatalks_default"
        const val DEFAULT_TAG = "datatalks"
        const val NOTIFICATION_ID = 1
        const val ICON_KEY = "se.datatalks.push.notification_icon"
        const val COLOR_KEY = "se.datatalks.push.notification_color"
        const val CHANNEL_NAME_KEY = "se.datatalks.push.notification_channel_name"
        const val FIREBASE_ICON_KEY = "com.google.firebase.messaging.default_notification_icon"
        const val FIREBASE_COLOR_KEY = "com.google.firebase.messaging.default_notification_color"
        const val IMAGE_TIMEOUT_MILLIS = 5_000
        const val LARGE_ICON_WAIT_MILLIS = 2L * IMAGE_TIMEOUT_MILLIS
        const val MAX_IMAGE_BYTES = 5 * 1024 * 1024
        const val MAX_IMAGE_WIDTH = 1024

        // Android shows the large icon at 64dp at most, so 256 px is sharp on any screen.
        const val MAX_LARGE_ICON_WIDTH = 256
        val COLOR_PATTERN = Regex("^#[0-9A-Fa-f]{6}$")

        /** Null on failure; the push is then shown without its picture. Only `https` URLs, as the payload spec requires. */
        fun downloadImage(url: String): Bitmap? = download(url, MAX_IMAGE_WIDTH)

        /** Null on failure; the push is then shown without the large icon. */
        fun downloadLargeIcon(url: String): Bitmap? = download(url, MAX_LARGE_ICON_WIDTH)

        private fun download(url: String, maxWidth: Int): Bitmap? {
            if (!url.startsWith("https://", ignoreCase = true)) return null
            return try {
                val connection = URL(url).openConnection() as HttpURLConnection
                connection.connectTimeout = IMAGE_TIMEOUT_MILLIS
                connection.readTimeout = IMAGE_TIMEOUT_MILLIS
                try {
                    if (connection.responseCode != HttpURLConnection.HTTP_OK) return null
                    decode(connection.inputStream.use(::readLimited) ?: return null, maxWidth)
                } finally {
                    connection.disconnect()
                }
            } catch (e: IOException) {
                Log.d(TAG, "A push's picture couldn't be loaded: ${e.javaClass.simpleName}")
                null
            }
        }

        /** Null when the body exceeds MAX_IMAGE_BYTES. */
        private fun readLimited(stream: InputStream): ByteArray? {
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(16 * 1024)
            while (true) {
                val read = stream.read(buffer)
                if (read < 0) return output.toByteArray()
                output.write(buffer, 0, read)
                if (output.size() > MAX_IMAGE_BYTES) return null
            }
        }

        // Notification bitmaps are sent over Binder, so a large image is downsampled while decoding.
        private fun decode(bytes: ByteArray, maxWidth: Int): Bitmap? {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
            var sample = 1
            while (bounds.outWidth / sample > maxWidth) sample *= 2
            return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample })
        }
    }
}
