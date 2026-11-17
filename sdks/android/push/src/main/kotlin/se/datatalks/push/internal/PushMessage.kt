package se.datatalks.push.internal

import org.json.JSONException
import org.json.JSONObject
import se.datatalks.push.DataTalksMessage

/** A push of ours, read from its `dt_*` keys (`spec/payload/payload-v1.md`). Unknown keys are ignored. */
internal data class PushMessage(
    val uid: String?,
    val title: String?,
    val body: String?,
    val image: String?,
    val link: String?,
    val dataText: String?,
    val channel: String?,
    val sound: String?,
    val collapse: String?,
    /** Accent colour, `#RRGGBB`; the renderer ignores any other format. */
    val color: String? = null,
    /** Large icon, an `https` URL. */
    val largeIcon: String? = null,
) {
    /** The notification tag: a newer push with the same tag replaces the older one. */
    val tag: String? get() = collapse ?: uid

    val data: JSONObject? get() = parseData(dataText)

    fun toPublic() = DataTalksMessage(uid, title, body, image, link, data)

    companion object {
        /** Null for a message that is not from Data Talks (no `dt_v` key). */
        fun from(values: Map<String, String>): PushMessage? {
            if (!values.containsKey("dt_v")) return null
            return PushMessage(
                uid = values["dt_uid"],
                title = values["dt_title"],
                body = values["dt_body"],
                image = values["dt_image"],
                link = values["dt_link"],
                dataText = values["dt_data"],
                channel = values["dt_channel"],
                sound = values["dt_sound"],
                collapse = values["dt_collapse"],
                color = values["dt_color"],
                largeIcon = values["dt_large_icon"],
            )
        }

        fun parseData(text: String?): JSONObject? {
            if (text.isNullOrEmpty()) return null
            return try {
                JSONObject(text)
            } catch (e: JSONException) {
                null
            }
        }
    }
}
