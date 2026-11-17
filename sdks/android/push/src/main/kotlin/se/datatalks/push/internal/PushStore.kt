package se.datatalks.push.internal

import android.annotation.SuppressLint
import android.content.Context
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/** The FCM token or FID this install reports, with its `fcm_token_type`. */
internal data class PushValue(val value: String, val type: String) {
    companion object {
        const val TYPE_FID = "fcm_fid"
        const val TYPE_TOKEN = "fcm_token"
    }
}

/** The single pending identity call; a later identify or logout replaces it. */
internal sealed interface PendingIdentity {
    data object Logout : PendingIdentity

    data class Identify(val externalId: String?, val email: String?, val identityToken: String?) : PendingIdentity
}

/**
 * The last identity the service accepted for this install: a fingerprint (no id or email in clear), the UTC day (days
 * since the epoch), and whether it was verified. A repeat on the same day is answered from this without a call.
 */
internal data class AcceptedIdentity(val fingerprint: String, val day: Long, val verified: Boolean)

/** SHA-256 of the install id, external id, email and whether an identity token was passed. */
internal fun identityFingerprint(installId: String, identity: PendingIdentity.Identify): String {
    val text = listOf(installId, identity.externalId.orEmpty(), identity.email.orEmpty(), if (identity.identityToken == null) "0" else "1")
        .joinToString("\u0000")
    return MessageDigest.getInstance("SHA-256").digest(text.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
}

/** What deleting the install on the service needs once the local store is wiped. */
internal data class PendingDelete(val appKey: String, val baseUrl: String?, val installId: String, val deviceSecret: String)

/**
 * A push event waiting for `POST /devices/{install_id}/events`. [eventId] is generated once, so a retry after a lost
 * response resends the same ids; [occurredAt] is in epoch milliseconds.
 */
internal data class PushEvent(val eventId: String, val type: String, val uid: String, val occurredAt: Long, val link: String?) {
    companion object {
        const val DELIVERY = "delivery"
        const val OPEN = "open"
        const val CLICK = "click"
    }
}

/**
 * The SDK's on-device storage. Keys, ids, secrets, the FCM value and identities are encrypted ([ValueCrypto]); the rest
 * are plain flags. Use it off the main thread: writes use `commit()`, because a device secret that never reaches the disk
 * cannot be fetched again.
 */
@SuppressLint("ApplySharedPref")
internal class PushStore(context: Context, private val crypto: ValueCrypto = KeystoreCrypto) {
    private val prefs = context.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    // Decrypted values. A value the Keystore failed to encrypt lives only here, so the next process registers a new install.
    private val secure = ConcurrentHashMap<String, String>()

    var appKey: String?
        get() = readSecure(APP_KEY)
        set(value) = writeSecure(APP_KEY, value)

    var baseUrl: String?
        get() = prefs.getString(BASE_URL, null)
        set(value) = edit { putString(BASE_URL, value) }

    /** [se.datatalks.push.DataTalksPushOptions.openLinks] from the last start, kept because a tap can arrive before a start. */
    var openLinks: Boolean
        get() = prefs.getBoolean(OPEN_LINKS, true)
        set(value) = edit { putBoolean(OPEN_LINKS, value) }

    var installId: String?
        get() = readSecure(INSTALL_ID)
        set(value) = writeSecure(INSTALL_ID, value)

    var deviceSecret: String?
        get() = readSecure(DEVICE_SECRET)
        set(value) = writeSecure(DEVICE_SECRET, value)

    val pushValue: PushValue?
        get() {
            val value = readSecure(PUSH_VALUE) ?: return null
            val type = prefs.getString(PUSH_VALUE_TYPE, null) ?: return null
            return PushValue(value, type)
        }

    var pushValueChanged: Boolean
        get() = prefs.getBoolean(PUSH_VALUE_CHANGED, false)
        set(value) = edit { putBoolean(PUSH_VALUE_CHANGED, value) }

    /** The day of the last answer to a registration, in days since the epoch. */
    val registeredOn: Long
        get() = prefs.getLong(REGISTERED_ON, NEVER)

    val reportedPermission: String?
        get() = prefs.getString(REPORTED_PERMISSION, null)

    var permissionAsked: Boolean
        get() = prefs.getBoolean(PERMISSION_ASKED, false)
        set(value) = edit { putBoolean(PERMISSION_ASKED, value) }

    var pendingIdentity: PendingIdentity?
        get() = readSecure(PENDING_IDENTITY)?.let(::parseIdentity)
        set(value) = writeSecure(PENDING_IDENTITY, value?.let(::formatIdentity))

    /** See [AcceptedIdentity]. Cleared by a logout, a refused identify, a new install and a new app key. */
    var acceptedIdentity: AcceptedIdentity?
        get() = readSecure(ACCEPTED_IDENTITY)?.let(::parseAccepted)
        set(value) = writeSecure(ACCEPTED_IDENTITY, value?.let { "${it.day}|${if (it.verified) 1 else 0}|${it.fingerprint}" })

    /**
     * Today's answer for [identity] on this install when nothing else is queued, so the identify can be skipped; null when
     * it must be sent. Token-only identifies are never skipped: different users' tokens look the same here.
     */
    fun repeatedAnswer(identity: PendingIdentity, day: Long): Boolean? {
        if (identity !is PendingIdentity.Identify || pendingIdentity != null) return null
        if (identity.externalId.isNullOrEmpty() && identity.email.isNullOrEmpty()) return null
        val installId = installId ?: return null
        val accepted = acceptedIdentity ?: return null
        return accepted.verified.takeIf { accepted.day == day && accepted.fingerprint == identityFingerprint(installId, identity) }
    }

    /**
     * Queues [identity] unless [repeatedAnswer] has today's answer for it, which is returned instead. Shares a lock with
     * [finishIdentity], so a sync finishing a call can't interleave.
     */
    fun queueIdentity(identity: PendingIdentity, day: Long): Boolean? = synchronized(IDENTITY_LOCK) {
        repeatedAnswer(identity, day) ?: run {
            pendingIdentity = identity
            null
        }
    }

    /**
     * Completes the call for [sent]: records [accepted] (null for none) and clears the pending call only if it is still
     * [sent], so an identify or logout queued during the call goes next.
     */
    fun finishIdentity(sent: PendingIdentity, accepted: AcceptedIdentity?) = synchronized(IDENTITY_LOCK) {
        acceptedIdentity = accepted
        if (pendingIdentity == sent) pendingIdentity = null
    }

    var pendingOptIn: Boolean?
        get() = if (prefs.contains(PENDING_OPT_IN)) prefs.getBoolean(PENDING_OPT_IN, false) else null
        set(value) = edit { if (value == null) remove(PENDING_OPT_IN) else putBoolean(PENDING_OPT_IN, value) }

    var pendingDelete: PendingDelete?
        get() = readSecure(PENDING_DELETE)?.let(::parseDelete)
        set(value) = writeSecure(PENDING_DELETE, value?.let(::formatDelete))

    /** No call before this time, in epoch milliseconds, set from a `Retry-After`. */
    var notBefore: Long
        get() = prefs.getLong(NOT_BEFORE, 0)
        set(value) = edit { putLong(NOT_BEFORE, value) }

    var failedAttempts: Int
        get() = prefs.getInt(FAILED_ATTEMPTS, 0)
        set(value) = edit { putInt(FAILED_ATTEMPTS, value) }

    var configExpiresAt: Long
        get() = prefs.getLong(CONFIG_EXPIRES_AT, 0)
        set(value) = edit { putLong(CONFIG_EXPIRES_AT, value) }

    /** A change clears the accepted identity: an identify accepted before may now be refused. */
    var requireVerifiedIdentity: Boolean
        get() = prefs.getBoolean(REQUIRE_VERIFIED_IDENTITY, false)
        set(value) {
            if (value != requireVerifiedIdentity) acceptedIdentity = null
            edit { putBoolean(REQUIRE_VERIFIED_IDENTITY, value) }
        }

    /** Stores [value] if it differs from the current one; returns whether it changed. */
    fun updatePushValue(value: PushValue): Boolean {
        if (pushValue == value) return false
        writeSecure(PUSH_VALUE, value.value)
        edit {
            putString(PUSH_VALUE_TYPE, value.type)
            putBoolean(PUSH_VALUE_CHANGED, true)
        }
        return true
    }

    /** The registration was accepted, or refused for good: nothing more to send today. */
    fun markRegistered(day: Long, permission: String) = edit {
        putLong(REGISTERED_ON, day)
        putString(REPORTED_PERMISSION, permission)
        putBoolean(PUSH_VALUE_CHANGED, false)
    }

    /**
     * Forgets an install that is unknown to the service or whose secret is lost; the next registration creates a new one.
     * Its queued events are dropped too, since the service matches them to pushes sent to the old install.
     */
    fun dropInstall() {
        installId = null
        deviceSecret = null
        acceptedIdentity = null
        synchronized(EVENTS_LOCK) {
            edit {
                remove(REGISTERED_ON)
                remove(EVENTS)
                remove(OPEN_EVENTS)
            }
        }
    }

    fun replaceAppKey(key: String) {
        appKey = key
        // A different key can mean a different environment, which has not seen this identity.
        acceptedIdentity = null
        edit { remove(CONFIG_EXPIRES_AT) }
    }

    /**
     * Queues an event until the service answers it, keeping only the newest [MAX_EVENTS]. Thread-safe: deliveries are
     * written from the messaging service's thread while taps and the sync write from others.
     */
    fun queueEvent(type: String, uid: String, occurredAt: Long, link: String? = null) = synchronized(EVENTS_LOCK) {
        val events = readEvents()
        events.add(PushEvent(UUID.randomUUID().toString(), type, uid, occurredAt, link))
        writeEvents(events.takeLast(MAX_EVENTS))
    }

    /** The events still to send, oldest first. Events older than 30 days are dropped, as the service would refuse them. */
    fun pendingEvents(now: Long): List<PushEvent> = synchronized(EVENTS_LOCK) {
        val events = readEvents()
        val fresh = events.filter { now - it.occurredAt <= MAX_EVENT_AGE_MILLIS }
        if (fresh.size != events.size) writeEvents(fresh)
        fresh
    }

    /** Removes the events the service has answered. */
    fun removeEvents(eventIds: Set<String>) = synchronized(EVENTS_LOCK) {
        val events = readEvents()
        val left = events.filterNot { it.eventId in eventIds }
        if (left.size != events.size) writeEvents(left)
    }

    val hasEvents: Boolean
        get() = synchronized(EVENTS_LOCK) { readEvents().isNotEmpty() }

    fun wipe() {
        secure.clear()
        prefs.edit().clear().commit()
    }

    private fun readSecure(name: String): String? {
        secure[name]?.let { return it }
        val stored = prefs.getString(name, null) ?: return null
        return try {
            crypto.decrypt(stored).also { secure[name] = it }
        } catch (e: Exception) {
            // Keystore failures have no common type, and the value is lost either way.
            Log.w(TAG, "A stored value can't be read: ${e.javaClass.simpleName}")
            null
        }
    }

    private fun writeSecure(name: String, value: String?) {
        if (value == null) {
            secure.remove(name)
            edit { remove(name) }
            return
        }

        secure[name] = value
        val encrypted = try {
            crypto.encrypt(value)
        } catch (e: Exception) {
            Log.w(TAG, "A value can't be encrypted, so it stays in memory: ${e.javaClass.simpleName}")
            null
        }
        edit { if (encrypted == null) remove(name) else putString(name, encrypted) }
    }

    private inline fun edit(change: android.content.SharedPreferences.Editor.() -> Unit) {
        val editor = prefs.edit()
        editor.change()
        editor.commit()
    }

    private fun formatIdentity(identity: PendingIdentity): String = when (identity) {
        PendingIdentity.Logout -> JSONObject().put("op", "logout")
        is PendingIdentity.Identify -> JSONObject()
            .put("op", "identify")
            .putOpt("external_id", identity.externalId)
            .putOpt("email", identity.email)
            .putOpt("identity_token", identity.identityToken)
    }.toString()

    private fun parseIdentity(text: String): PendingIdentity {
        val json = JSONObject(text)
        if (json.getString("op") == "logout") return PendingIdentity.Logout
        return PendingIdentity.Identify(json.optStringOrNull("external_id"), json.optStringOrNull("email"), json.optStringOrNull("identity_token"))
    }

    private fun formatDelete(delete: PendingDelete): String = JSONObject()
        .put("app_key", delete.appKey)
        .putOpt("base_url", delete.baseUrl)
        .put("install_id", delete.installId)
        .put("device_secret", delete.deviceSecret)
        .toString()

    private fun parseDelete(text: String): PendingDelete {
        val json = JSONObject(text)
        return PendingDelete(json.getString("app_key"), json.optStringOrNull("base_url"), json.getString("install_id"), json.getString("device_secret"))
    }

    private fun JSONObject.optStringOrNull(name: String): String? = if (has(name)) getString(name) else null

    // Call under EVENTS_LOCK. Opens stored in the legacy format (OPEN_EVENTS) are moved into the queue on the first read.
    private fun readEvents(): MutableList<PushEvent> {
        val stored = JSONArray(prefs.getString(EVENTS, "[]"))
        val events = (0 until stored.length()).map { index ->
            val event = stored.getJSONObject(index)
            PushEvent(event.getString("event_id"), event.getString("type"), event.getString("uid"), event.getLong("occurred_at"), event.optStringOrNull("link"))
        }.toMutableList()

        val legacy = prefs.getString(OPEN_EVENTS, null) ?: return events
        val opens = JSONArray(legacy)
        for (index in 0 until opens.length()) {
            val open = opens.getJSONObject(index)
            events.add(PushEvent(UUID.randomUUID().toString(), PushEvent.OPEN, open.getString("uid"), open.getLong("opened_at"), null))
        }

        events.sortBy { it.occurredAt }
        writeEvents(events.takeLast(MAX_EVENTS))
        return events.takeLast(MAX_EVENTS).toMutableList()
    }

    private fun writeEvents(events: List<PushEvent>) {
        val stored = JSONArray()
        events.forEach { event ->
            stored.put(
                JSONObject()
                    .put("event_id", event.eventId)
                    .put("type", event.type)
                    .put("uid", event.uid)
                    .put("occurred_at", event.occurredAt)
                    .putOpt("link", event.link),
            )
        }

        edit {
            putString(EVENTS, stored.toString())
            remove(OPEN_EVENTS)
        }
    }

    private fun parseAccepted(stored: String): AcceptedIdentity? {
        val parts = stored.split('|', limit = 3)
        if (parts.size != 3) return null
        val day = parts[0].toLongOrNull() ?: return null
        return AcceptedIdentity(parts[2], day, parts[1] == "1")
    }

    private companion object {
        const val TAG = "DataTalksPush"
        const val FILE = "se.datatalks.push"
        const val NEVER = -1L
        const val MAX_EVENTS = 200
        const val MAX_EVENT_AGE_MILLIS = 30L * 24 * 60 * 60 * 1_000

        // All PushStore instances in a process share one file, so they share the locks too.
        val EVENTS_LOCK = Any()
        val IDENTITY_LOCK = Any()

        const val APP_KEY = "app_key"
        const val BASE_URL = "base_url"
        const val OPEN_LINKS = "open_links"
        const val INSTALL_ID = "install_id"
        const val DEVICE_SECRET = "device_secret"
        const val PUSH_VALUE = "push_value"
        const val PUSH_VALUE_TYPE = "push_value_type"
        const val PUSH_VALUE_CHANGED = "push_value_changed"
        const val REGISTERED_ON = "registered_on"
        const val REPORTED_PERMISSION = "reported_permission"
        const val PERMISSION_ASKED = "permission_asked"
        const val PENDING_IDENTITY = "pending_identity"
        const val PENDING_OPT_IN = "pending_opt_in"
        const val PENDING_DELETE = "pending_delete"
        const val NOT_BEFORE = "not_before"
        const val FAILED_ATTEMPTS = "failed_attempts"
        const val CONFIG_EXPIRES_AT = "config_expires_at"
        const val REQUIRE_VERIFIED_IDENTITY = "require_verified_identity"
        const val ACCEPTED_IDENTITY = "accepted_identity"
        const val EVENTS = "events"

        // Legacy format: opens only, as {uid, opened_at}.
        const val OPEN_EVENTS = "open_events"
    }
}
