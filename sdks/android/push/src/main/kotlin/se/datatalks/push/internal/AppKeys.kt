package se.datatalks.push.internal

internal object AppKeys {
    // dtpk_{env}_ and 32 base62 characters. Keys issued before 1.0 have live_ or test_ after the environment; they still work.
    private val SHAPE = Regex("^dtpk_(stg|prd)_(?:(?:live|test)_)?[0-9A-Za-z]{32}$")

    /** The API base URL for the key's environment, or null for a malformed key. */
    fun baseUrl(appKey: String): String? = when (SHAPE.find(appKey)?.groupValues?.get(1)) {
        "prd" -> "https://push.datatalks.se/v1"
        "stg" -> "https://push.staging.datatalks.se/v1"
        else -> null
    }
}
