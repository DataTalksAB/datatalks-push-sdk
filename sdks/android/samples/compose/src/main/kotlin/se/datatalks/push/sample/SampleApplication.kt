package se.datatalks.push.sample

import android.app.Application
import android.content.Context
import androidx.compose.runtime.mutableStateListOf
import org.json.JSONObject
import se.datatalks.push.DataTalksIdentityResult
import se.datatalks.push.DataTalksMessage
import se.datatalks.push.DataTalksPush
import se.datatalks.push.DataTalksPushListener
import se.datatalks.push.DataTalksPushOptions

class SampleApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        DataTalksPush.setListener(SampleEvents)

        val settings = SampleSettings(this)
        settings.appKey?.let { start(this, it, settings.baseUrl) }
    }

    companion object {
        fun start(context: Context, appKey: String, baseUrl: String?) {
            DataTalksPush.initialize(context, appKey, DataTalksPushOptions(baseUrl))
        }
    }
}

/** What the SDK reported, newest first, worded as in the other samples. */
object SampleEvents : DataTalksPushListener {
    val lines = mutableStateListOf<String>()

    fun add(line: String) {
        lines.add(0, line)
    }

    override fun onMessageReceived(message: DataTalksMessage) {
        add("Message ${message.uid ?: "without an id"}: ${message.title.orEmpty()} ${message.body.orEmpty()}".trim())
    }

    override fun onNotificationOpened(deepLink: String?, data: JSONObject?) {
        add("Opened: ${deepLink ?: "the app"}, data: ${data ?: "none"}")
    }

    override fun onIdentityResult(result: DataTalksIdentityResult) {
        add(result.errorCode?.let { "Identify refused: $it ${result.errorDetail.orEmpty()}".trim() } ?: "Identify accepted, verified: ${result.verified}")
    }
}

/** The key and host entered on screen, saved so the next launch starts the same way. */
class SampleSettings(context: Context) {
    private val prefs = context.getSharedPreferences("sample", Context.MODE_PRIVATE)

    var appKey: String?
        get() = prefs.getString("app_key", null)
        set(value) = prefs.edit().putString("app_key", value).apply()

    var baseUrl: String?
        get() = prefs.getString("base_url", null)
        set(value) = prefs.edit().putString("base_url", value).apply()
}
