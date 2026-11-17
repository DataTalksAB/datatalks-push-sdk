package se.datatalks.push.internal

import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import se.datatalks.push.DataTalksIdentityResult
import java.io.IOException
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.UUID

/** RFC 3339 timestamps in UTC, the format of `occurred_at`. */
internal object Timestamps {
    fun utc(millis: Long): String {
        // A new formatter per call: SimpleDateFormat isn't thread-safe, and java.time needs API 26.
        val format = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.ROOT)
        format.timeZone = TimeZone.getTimeZone("UTC")
        return format.format(Date(millis))
    }
}

internal sealed interface SyncOutcome {
    data object Done : SyncOutcome

    /** Retry after the delay the service gave (429, 503). */
    data class RetryAfter(val seconds: Long) : SyncOutcome

    /** Another 5xx or a network error: exponential backoff, capped at one hour. */
    data object Backoff : SyncOutcome
}

/**
 * Brings the service up to date with the store, in this order: pending delete, config, registration, identity call,
 * consent, events. Each step reads what is still pending, so running twice is safe and the next run resumes after a
 * failure. The SDK rules are in `info.description` of `spec/openapi/push-v1.yaml`.
 */
internal class PushSync(
    private val store: PushStore,
    private val values: PushValueSource,
    private val facts: DeviceFacts,
    private val onIdentityResult: (DataTalksIdentityResult) -> Unit,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    private sealed interface Step {
        data object Next : Step

        /** The install was replaced: start over with the new one. */
        data object Restart : Step

        data class Stop(val outcome: SyncOutcome) : Step
    }

    /** The app is disabled or the key refused: no calls until the next process start or a new key, as they would fail again. */
    @Volatile
    var stopped = false

    fun isDue(): Boolean {
        if (stopped) return false
        if (store.pendingDelete != null) return true
        if (store.appKey == null) return false
        return store.pendingIdentity != null ||
            store.pendingOptIn != null ||
            (store.installId != null && store.deviceSecret != null && store.hasEvents) ||
            registrationIsDue(facts.permission())
    }

    fun run(): SyncOutcome = synchronized(this) {
        try {
            runSteps()
        } catch (e: IOException) {
            Log.d(TAG, "The service can't be reached: ${e.javaClass.simpleName}")
            SyncOutcome.Backoff
        }
    }

    private fun runSteps(): SyncOutcome {
        if (stopped) return SyncOutcome.Done

        val wait = (store.notBefore - clock()) / MILLIS_PER_SECOND
        if (wait > 0) return SyncOutcome.RetryAfter(wait + 1)

        (sendPendingDelete() as? Step.Stop)?.let { return it.outcome }

        val key = store.appKey ?: return SyncOutcome.Done
        val baseUrl = store.baseUrl ?: AppKeys.baseUrl(key) ?: return SyncOutcome.Done
        val api = PushApi(baseUrl, key)

        (readConfig(api) as? Step.Stop)?.let { return it.outcome }

        repeat(MAX_RESTARTS) {
            var step = register(api)
            if (step == Step.Next) step = sendIdentity(api)
            if (step == Step.Next) step = sendConsent(api)
            if (step == Step.Next) step = sendEvents(api)
            when (step) {
                Step.Next -> return SyncOutcome.Done
                Step.Restart -> Unit
                is Step.Stop -> return step.outcome
            }
        }

        return SyncOutcome.Backoff
    }

    private fun sendPendingDelete(): Step {
        val pending = store.pendingDelete ?: return Step.Next
        val api = PushApi(pending.baseUrl ?: AppKeys.baseUrl(pending.appKey) ?: return Step.Next, pending.appKey)
        val response = api.call("DELETE", "/devices/${pending.installId}", pending.deviceSecret)
        if (!response.isSuccess) stopFor(response)?.let { return it }
        store.pendingDelete = null
        return Step.Next
    }

    private fun readConfig(api: PushApi): Step {
        if (clock() < store.configExpiresAt) return Step.Next

        val response = api.call("GET", "/config")
        if (!response.isSuccess) {
            return stopFor(response) ?: Step.Next.also { Log.w(TAG, "The app's settings were refused: ${response.code}") }
        }

        val config = response.json ?: return Step.Stop(SyncOutcome.Backoff)
        store.requireVerifiedIdentity = config.optBoolean("require_verified_identity")
        store.configExpiresAt = clock() + config.optLong("refresh_after_seconds", DEFAULT_CONFIG_SECONDS) * MILLIS_PER_SECOND
        if (config.optJSONObject("platforms")?.has("android") != true) {
            Log.w(TAG, "The app isn't set up for Android in the portal.")
            stopped = true
            return Step.Stop(SyncOutcome.Done)
        }

        return Step.Next
    }

    private fun register(api: PushApi): Step {
        val lookup = values.current()
        if (lookup is PushValueLookup.Found) store.updatePushValue(lookup.value)

        val permission = facts.permission()
        if (!registrationIsDue(permission)) return Step.Next

        // No FCM value yet. The later steps need an install too, so stop here.
        val value = store.pushValue
            ?: return Step.Stop(if (lookup == PushValueLookup.NotConfigured) SyncOutcome.Done else SyncOutcome.Backoff)

        val installId = store.installId ?: UUID.randomUUID().toString().also { store.installId = it }
        val body = JSONObject(facts.metadata())
            .put("install_id", installId)
            .put("platform", "android")
            .put("fcm_token", value.value)
            .put("fcm_token_type", value.type)
            .put("os_permission", permission)

        val response = api.call("POST", "/devices", store.deviceSecret, body)
        if (response.isSuccess) {
            response.json?.optString("device_secret")?.takeIf { it.isNotEmpty() }?.let { store.deviceSecret = it }
            store.markRegistered(today(), permission)
            return Step.Next
        }

        stopFor(response)?.let { return it }
        if (response.code == INSTALL_ID_CONFLICT || response.code == DEVICE_AUTH_FAILED) {
            store.dropInstall()
            return Step.Restart
        }

        // Never retried unchanged: a new token, a permission change or the next daily refresh sends it again.
        Log.w(TAG, "The registration was refused: ${response.code}")
        store.markRegistered(today(), permission)
        return Step.Next
    }

    private fun sendIdentity(api: PushApi): Step {
        val pending = store.pendingIdentity ?: return Step.Next
        val installId = store.installId ?: return Step.Next
        val secret = store.deviceSecret ?: return Step.Next

        val response = when (pending) {
            PendingIdentity.Logout -> api.call("POST", "/devices/$installId/logout", secret)
            is PendingIdentity.Identify -> api.call("POST", "/devices/$installId/identify", secret, identifyBody(pending))
        }

        if (!response.isSuccess) stopFor(response)?.let { return it }

        // A 2xx without this field (a captive portal page, for example) does not prove the identify arrived.
        val verified = response.json?.opt("identity_verified") as? Boolean

        // Finished or refused: never replay an identify after a 401 (spec). Record what the service now holds; a call
        // the app queued meanwhile goes next.
        val accepted = if (response.isSuccess && pending is PendingIdentity.Identify && verified != null) {
            AcceptedIdentity(identityFingerprint(installId, pending), today(), verified)
        } else {
            null
        }
        store.finishIdentity(pending, accepted)

        if (pending is PendingIdentity.Identify) {
            onIdentityResult(
                if (response.isSuccess) {
                    DataTalksIdentityResult(verified ?: false)
                } else {
                    DataTalksIdentityResult(false, response.code, response.detail)
                },
            )
        }

        if (response.code == DEVICE_AUTH_FAILED) {
            store.dropInstall()
            return Step.Restart
        }

        return Step.Next
    }

    private fun sendConsent(api: PushApi): Step {
        val optIn = store.pendingOptIn ?: return Step.Next
        val installId = store.installId ?: return Step.Next
        val secret = store.deviceSecret ?: return Step.Next

        val response = api.call("PUT", "/devices/$installId/consent", secret, JSONObject().put("marketing_opt_in", optIn))
        if (!response.isSuccess) stopFor(response)?.let { return it }

        if (response.code == DEVICE_AUTH_FAILED) {
            // The pending choice is kept for the new install.
            store.dropInstall()
            return Step.Restart
        }

        store.pendingOptIn = null
        return Step.Next
    }

    /**
     * Sends deliveries, opens and clicks, oldest first, in calls of at most [MAX_EVENTS_PER_CALL] within the device routes'
     * body limit. Any per-event result (accepted, duplicate, skipped) removes the event; a 429, 5xx, network error, 404
     * or a 2xx without results keeps them all for the next run.
     */
    private fun sendEvents(api: PushApi): Step {
        val installId = store.installId ?: return Step.Next
        val secret = store.deviceSecret ?: return Step.Next

        repeat(MAX_EVENT_CALLS_PER_RUN) {
            val batch = eventBatch(store.pendingEvents(clock()))
            if (batch.isEmpty()) return Step.Next

            val body = JSONObject().put("events", JSONArray(batch.map(::eventJson)))
            val response = api.call("POST", "/devices/$installId/events", secret, body)
            if (response.isSuccess && response.json?.optJSONArray("results") == null) {
                // Not a response from the service (a captive portal page, for example): nothing proves the events arrived.
                Log.w(TAG, "The events answer has no results.")
                return Step.Stop(SyncOutcome.Backoff)
            }

            if (!response.isSuccess) {
                stopFor(response)?.let { return it }
                if (response.code == DEVICE_AUTH_FAILED) {
                    // The events belong to the old install and are dropped with it.
                    store.dropInstall()
                    return Step.Restart
                }

                if (response.status == STATUS_NOT_FOUND) {
                    // The route is missing (an unknown install gets a 401): an ingress older than API 1.1.0. Keep the
                    // events until the service takes them.
                    Log.w(TAG, "The service doesn't take events yet.")
                    return Step.Stop(SyncOutcome.Backoff)
                }

                // Any other 4xx would be refused again: the spec forbids retrying a 4xx unchanged.
                Log.w(TAG, "Events were refused: ${response.code ?: response.status}")
            }

            store.removeEvents(batch.map { it.eventId }.toSet())
        }

        // More events than one run sends: the next run continues, which keeps within the per-install rate limit.
        return Step.Next
    }

    private fun eventBatch(events: List<PushEvent>): List<PushEvent> {
        val batch = mutableListOf<PushEvent>()
        var bytes = EVENTS_ENVELOPE_BYTES
        for (event in events) {
            val size = eventJson(event).toString().toByteArray(Charsets.UTF_8).size + 1
            if (batch.size == MAX_EVENTS_PER_CALL || (batch.isNotEmpty() && bytes + size > MAX_EVENTS_BODY_BYTES)) break
            batch.add(event)
            bytes += size
        }

        return batch
    }

    private fun eventJson(event: PushEvent): JSONObject = JSONObject()
        .put("event_id", event.eventId)
        .put("type", event.type)
        .put("uid", event.uid)
        .put("occurred_at", Timestamps.utc(event.occurredAt))
        .putOpt("link", event.link)

    private fun registrationIsDue(permission: String): Boolean =
        store.pushValueChanged || store.installId == null || store.registeredOn != today() || store.reportedPermission != permission

    /** The responses that end the run; null for those the calling step handles itself. */
    private fun stopFor(response: ApiResponse): Step.Stop? = when {
        response.status == STATUS_TOO_MANY_REQUESTS || response.status == STATUS_UNAVAILABLE -> {
            val seconds = response.retryAfterSeconds ?: DEFAULT_RETRY_AFTER_SECONDS
            store.notBefore = clock() + seconds * MILLIS_PER_SECOND
            Step.Stop(SyncOutcome.RetryAfter(seconds))
        }

        response.status >= STATUS_SERVER_ERROR -> Step.Stop(SyncOutcome.Backoff)

        response.code == APP_DISABLED || response.code == KEY_INVALID || response.code == KEY_WRONG_ENVIRONMENT -> {
            Log.w(TAG, "The service stopped this app: ${response.code}")
            stopped = true
            Step.Stop(SyncOutcome.Done)
        }

        else -> null
    }

    private fun identifyBody(identify: PendingIdentity.Identify): JSONObject = JSONObject()
        .putOpt("external_id", identify.externalId)
        .putOpt("email", identify.email)
        .putOpt("identity_token", identify.identityToken)

    /** Days since the epoch, in UTC: the unit of the daily refresh and of the accepted identity. */
    fun today(): Long = clock() / MILLIS_PER_DAY

    companion object {
        private const val TAG = "DataTalksPush"
        private const val MILLIS_PER_SECOND = 1_000L
        private const val MILLIS_PER_DAY = 86_400_000L
        private const val MAX_RESTARTS = 3
        private const val DEFAULT_RETRY_AFTER_SECONDS = 60L
        private const val DEFAULT_CONFIG_SECONDS = 3_600L
        private const val STATUS_NOT_FOUND = 404
        private const val STATUS_TOO_MANY_REQUESTS = 429
        private const val STATUS_SERVER_ERROR = 500
        private const val STATUS_UNAVAILABLE = 503
        private const val APP_DISABLED = "app_disabled"
        private const val KEY_INVALID = "key_invalid"
        private const val KEY_WRONG_ENVIRONMENT = "key_wrong_environment"
        private const val INSTALL_ID_CONFLICT = "install_id_conflict"
        private const val DEVICE_AUTH_FAILED = "device_auth_failed"
        private const val BACKOFF_BASE_SECONDS = 30L
        private const val BACKOFF_MAX_SECONDS = 3_600L
        private const val MAX_EVENTS_PER_CALL = 50
        private const val MAX_EVENT_CALLS_PER_RUN = 4

        // Device routes accept bodies up to 8 KB (8192 bytes). Each event is measured as serialized; 50 deliveries fit.
        private const val MAX_EVENTS_BODY_BYTES = 8_000
        private const val EVENTS_ENVELOPE_BYTES = 13

        /** The delay after [attempt] failed tries, with jitter so devices don't all retry at once after an outage. */
        fun backoffSeconds(attempt: Int, spread: Double = Math.random()): Long {
            val full = minOf(BACKOFF_BASE_SECONDS shl attempt.coerceIn(0, 10), BACKOFF_MAX_SECONDS)
            return (full * (0.8 + 0.2 * spread)).toLong()
        }
    }
}
