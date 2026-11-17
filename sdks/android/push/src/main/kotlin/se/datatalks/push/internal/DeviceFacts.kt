package se.datatalks.push.internal

import android.content.Context
import android.content.pm.PackageInfo
import android.os.Build
import androidx.core.app.NotificationManagerCompat
import se.datatalks.push.DataTalksPermission
import java.util.Locale
import java.util.TimeZone

/** Device metadata for a registration, cut to the spec's maximum lengths: a longer value gets a 4xx, which is never retried. */
internal class DeviceFacts(private val context: Context, private val store: PushStore) {
    fun metadata(): Map<String, String> {
        val info = runCatching { context.packageManager.getPackageInfo(context.packageName, 0) }.getOrNull()
        return listOfNotNull(
            fact("app_version", info?.versionName, 64),
            fact("app_build", info?.let(::versionCode), 64),
            fact("os_version", Build.VERSION.RELEASE, 64),
            fact("device_manufacturer", Build.MANUFACTURER, 128),
            fact("device_model", Build.MODEL, 128),
            fact("locale", Locale.getDefault().toLanguageTag(), 35),
            fact("time_zone", TimeZone.getDefault().id, 64),
        ).toMap()
    }

    /** [permissionStatus] as its wire value (`os_permission`). */
    fun permission(): String = permissionStatus().value

    /**
     * Not determined only on Android 13+ before the prompt. Android does not expose whether an app has asked, so an app
     * that asks without [se.datatalks.push.DataTalksPush.requestPermission] still reads not determined after a denial.
     */
    fun permissionStatus(): DataTalksPermission = when {
        NotificationManagerCompat.from(context).areNotificationsEnabled() -> DataTalksPermission.AUTHORIZED
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && !store.permissionAsked -> DataTalksPermission.NOT_DETERMINED
        else -> DataTalksPermission.DENIED
    }

    private fun versionCode(info: PackageInfo): String =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode.toString() else @Suppress("DEPRECATION") info.versionCode.toString()

    private fun fact(name: String, value: String?, maxLength: Int): Pair<String, String>? {
        if (value.isNullOrBlank()) return null
        return name to cut(value, maxLength)
    }

    companion object {
        fun cut(value: String, maxLength: Int): String {
            if (value.length <= maxLength) return value
            val end = if (value[maxLength - 1].isHighSurrogate()) maxLength - 1 else maxLength
            return value.substring(0, end)
        }
    }
}
