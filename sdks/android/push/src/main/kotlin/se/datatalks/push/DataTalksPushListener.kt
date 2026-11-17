package se.datatalks.push

import org.json.JSONObject

/** Callbacks from the SDK, all on the main thread. Each has an empty default, so implement only the ones you need. */
interface DataTalksPushListener {
    /**
     * The user tapped a notification. The SDK opens [deepLink], or the launcher activity when there is no link or
     * [DataTalksPushOptions.openLinks] is false.
     */
    fun onNotificationOpened(deepLink: String?, data: JSONObject?) = Unit

    /** A Data Talks push arrived and the SDK rendered it. */
    fun onMessageReceived(message: DataTalksMessage) = Unit

    /** The result of a [DataTalksPush.identify] call. */
    fun onIdentityResult(result: DataTalksIdentityResult) = Unit
}

/** A Data Talks push, read from its `dt_*` data keys. */
class DataTalksMessage(
    val uid: String?,
    val title: String?,
    val body: String?,
    val imageUrl: String?,
    val deepLink: String?,
    val data: JSONObject?,
)

/**
 * The result of an identify. A non-null [errorCode] means it was refused and is not retried; [errorDetail] gives the
 * reason an identity token failed. It never reveals whether a matching profile exists.
 */
class DataTalksIdentityResult(
    val verified: Boolean,
    val errorCode: String? = null,
    val errorDetail: String? = null,
)

/** Whether the app may show notifications. [value] is the wire name shared with the service and the other SDKs. */
enum class DataTalksPermission(val value: String) {
    AUTHORIZED("authorized"),
    DENIED("denied"),

    /** Android 13+ only, before the app has asked through [DataTalksPush.requestPermission]. */
    NOT_DETERMINED("not_determined"),
}

/** Result of [DataTalksPush.requestPermission], delivered on the main thread. */
fun interface DataTalksPermissionCallback {
    fun onResult(permission: DataTalksPermission)
}

/**
 * Options for [DataTalksPush.initialize].
 *
 * @property baseUrl Overrides the host selected by the app key. Only for testing against a local ingress.
 * @property openLinks When false, a tap opens the launcher activity and passes the link to
 * [DataTalksPushListener.onNotificationOpened], for apps that route links themselves. The value is persisted, so it
 * also applies to a tap that launches the app before [DataTalksPush.initialize] runs.
 */
class DataTalksPushOptions @JvmOverloads constructor(
    val baseUrl: String? = null,
    val openLinks: Boolean = true,
)
