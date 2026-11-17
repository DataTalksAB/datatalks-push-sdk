package se.datatalks.push.internal

import org.json.JSONException
import org.json.JSONObject
import se.datatalks.push.BuildConfig
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL

/** An HTTP response: [json] is the parsed body; for an error, [code] and [detail] are read from it. */
internal class ApiResponse(val status: Int, val json: JSONObject?, val retryAfterSeconds: Long?) {
    val isSuccess: Boolean get() = status in 200..299

    val code: String? get() = error?.optString("code")?.takeIf { it.isNotEmpty() }

    val detail: String? get() = error?.optString("detail")?.takeIf { it.isNotEmpty() }

    private val error: JSONObject? get() = json?.optJSONObject("error")
}

/**
 * HTTP client for the push API. Uses `HttpURLConnection` rather than a library, so the SDK adds no dependency conflicts
 * to the app. Never logs: keys, secrets, tokens and identities pass through here.
 */
internal class PushApi(private val baseUrl: String, private val appKey: String) {
    /** @throws java.io.IOException on a network error, which is retried with backoff. */
    fun call(method: String, path: String, deviceSecret: String? = null, body: JSONObject? = null): ApiResponse {
        val connection = URL(baseUrl + path).openConnection() as HttpURLConnection
        try {
            connection.requestMethod = method
            connection.connectTimeout = CONNECT_TIMEOUT_MILLIS
            connection.readTimeout = READ_TIMEOUT_MILLIS
            connection.useCaches = false
            connection.setRequestProperty("Accept", "application/json")
            connection.setRequestProperty("X-DataTalks-App-Key", appKey)
            connection.setRequestProperty("X-DataTalks-SDK", SDK_HEADER)
            deviceSecret?.let { connection.setRequestProperty("X-DataTalks-Device-Secret", it) }

            if (body != null) {
                val bytes = body.toString().toByteArray(Charsets.UTF_8)
                connection.doOutput = true
                connection.setRequestProperty("Content-Type", "application/json")
                // No streaming mode: with it, a 401's body is lost, and the SDK needs its error code.
                connection.outputStream.use { it.write(bytes) }
            }

            val status = connection.responseCode
            val text = (if (status < 400) connection.inputStream else connection.errorStream)?.use(::readLimited)
            return ApiResponse(status, parse(text), connection.getHeaderField("Retry-After")?.toLongOrNull())
        } finally {
            connection.disconnect()
        }
    }

    private fun readLimited(stream: InputStream): String {
        val buffer = ByteArray(MAX_RESPONSE_BYTES)
        var total = 0
        while (total < buffer.size) {
            val read = stream.read(buffer, total, buffer.size - total)
            if (read < 0) break
            total += read
        }
        return String(buffer, 0, total, Charsets.UTF_8)
    }

    private fun parse(text: String?): JSONObject? {
        if (text.isNullOrEmpty()) return null
        return try {
            JSONObject(text)
        } catch (e: JSONException) {
            null
        }
    }

    private companion object {
        const val SDK_HEADER = "datatalks-push-android/${BuildConfig.SDK_VERSION}"
        const val CONNECT_TIMEOUT_MILLIS = 15_000
        const val READ_TIMEOUT_MILLIS = 30_000
        const val MAX_RESPONSE_BYTES = 64 * 1024
    }
}
