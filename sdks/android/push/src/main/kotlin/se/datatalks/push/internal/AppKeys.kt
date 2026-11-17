package se.datatalks.push.internal

internal object AppKeys {
    private val SHAPE = Regex("^dtpk_(stg|prd)_(live|test)_[0-9A-Za-z]{32}$")

    /** The API base URL for the key's environment, or null for a malformed key. */
    fun baseUrl(appKey: String): String? = when (SHAPE.find(appKey)?.groupValues?.get(1)) {
        "prd" -> "https://push.datatalks.se/v1"
        "stg" -> "https://push.staging.datatalks.se/v1"
        else -> null
    }
}
