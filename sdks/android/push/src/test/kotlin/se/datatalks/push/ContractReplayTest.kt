package se.datatalks.push

import com.google.common.truth.Truth.assertThat
import okhttp3.mockwebserver.MockResponse
import org.junit.After
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import se.datatalks.push.internal.PendingDelete
import se.datatalks.push.internal.PendingIdentity
import se.datatalks.push.internal.PushValue
import se.datatalks.push.internal.PushValueLookup
import se.datatalks.push.internal.SyncOutcome
import java.util.concurrent.TimeUnit

/**
 * Replays the spec's fixtures: the SDK must send what each step lists and handle each response as the spec says. Steps
 * the SDK can't produce (a missing key, an install it never held) are covered by the service's own replay.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class ContractReplayTest {
    private val harness = SyncHarness()
    private val server = harness.server
    private val store = harness.store
    private val sync = harness.sync

    @After
    fun stop() = harness.stop()

    @Test
    fun everyFixtureIsReplayedOrNotAndroids() {
        assertThat(Contract.fixtureNames()).containsExactlyElementsIn(REPLAYED + NOT_FOR_THE_ANDROID_SDK)
    }

    @Test
    fun config_isReadWithTheAppKey() {
        val fixture = Contract.fixture("config")
        store.configExpiresAt = 0
        harness.lookup = PushValueLookup.TryLater
        server.enqueue(fixture.response(0))

        sync.run()

        fixture.assertSent(0, taken())
        assertThat(store.requireVerifiedIdentity).isTrue()
    }

    @Test
    fun appDisabled_stopsCallingUntilTheNextAppStart() {
        val fixture = Contract.fixture("app-disabled")
        store.configExpiresAt = 0
        server.enqueue(fixture.response(0))

        assertThat(sync.run()).isEqualTo(SyncOutcome.Done)
        fixture.assertSent(0, taken())

        assertThat(sync.isDue()).isFalse()
        sync.run()
        assertThat(server.requestCount).isEqualTo(1)
    }

    @Test
    fun keyInvalid_stopsCalling() {
        val fixture = Contract.fixture("key-invalid")
        store.configExpiresAt = 0
        server.enqueue(fixture.response(1))

        assertThat(sync.run()).isEqualTo(SyncOutcome.Done)
        fixture.assertSent(1, taken())
        assertThat(sync.stopped).isTrue()
    }

    @Test
    fun keyWrongEnvironment_stopsCalling() {
        val fixture = Contract.fixture("key-wrong-environment")
        store.configExpiresAt = 0
        server.enqueue(fixture.response(0))

        assertThat(sync.run()).isEqualTo(SyncOutcome.Done)
        fixture.assertSent(0, taken())
        assertThat(sync.stopped).isTrue()
    }

    @Test
    fun registerAndroidNew_registersTheFid_AndKeepsTheSecret() {
        val fixture = Contract.fixture("register-android-new")
        store.installId = INSTALL_ID
        server.enqueue(fixture.response(0))

        assertThat(sync.run()).isEqualTo(SyncOutcome.Done)

        fixture.assertSent(0, taken(), "RegisterDeviceRequest")
        assertThat(store.deviceSecret).isEqualTo(Contract.DEVICE_SECRET)
    }

    @Test
    fun registerAndroidToken_registersTheRegistrationToken() {
        val fixture = Contract.fixture("register-android-token")
        store.installId = INSTALL_ID
        harness.lookup = PushValueLookup.Found(PushValue(fixture.requestBody(0).getString("fcm_token"), PushValue.TYPE_TOKEN))
        server.enqueue(fixture.response(0))

        assertThat(sync.run()).isEqualTo(SyncOutcome.Done)

        fixture.assertSent(0, taken(), "RegisterDeviceRequest")
    }

    @Test
    fun registerAndroidRefresh_sendsTheNewTokenWithTheSecret() {
        val fixture = Contract.fixture("register-android-refresh")
        registerFirst(fixture)

        harness.lookup = PushValueLookup.Found(PushValue(fixture.requestBody(1).getString("fcm_token"), PushValue.TYPE_FID))
        server.enqueue(fixture.response(1))
        assertThat(sync.run()).isEqualTo(SyncOutcome.Done)

        fixture.assertSent(1, taken(), "RegisterDeviceRequest")
        assertThat(store.deviceSecret).isEqualTo(Contract.DEVICE_SECRET)
    }

    @Test
    fun aConflict_registersAgainUnderANewInstallId() {
        val fixture = Contract.fixture("register-known-install-without-secret")
        registerFirst(fixture)

        store.deviceSecret = null
        store.pushValueChanged = true
        server.enqueue(fixture.response(1))
        server.enqueue(created())
        assertThat(sync.run()).isEqualTo(SyncOutcome.Done)
        fixture.assertSent(1, taken(), "RegisterDeviceRequest")
        assertThat(taken().getHeader("X-DataTalks-Device-Secret")).isNull()
        assertThat(store.installId).isNotEqualTo(INSTALL_ID)
        assertThat(store.deviceSecret).isEqualTo(Contract.DEVICE_SECRET)

        store.installId = INSTALL_ID
        store.deviceSecret = Contract.WRONG_SECRET
        store.pushValueChanged = true
        server.enqueue(fixture.response(2))
        server.enqueue(created())
        sync.run()
        fixture.assertSent(2, taken(), "RegisterDeviceRequest")
        taken()
        assertThat(store.installId).isNotEqualTo(INSTALL_ID)
    }

    @Test
    fun deviceAuthFailed_dropsTheInstall_AndRegistersAsANewOne() {
        val fixture = Contract.fixture("device-auth-failed")
        registerFirst(fixture)
        store.deviceSecret = Contract.WRONG_SECRET
        store.pendingIdentity = PendingIdentity.Logout
        server.enqueue(fixture.response(1))
        server.enqueue(created())

        assertThat(sync.run()).isEqualTo(SyncOutcome.Done)

        fixture.assertSent(1, taken())
        val again = taken()
        assertThat(again.path).isEqualTo("/v1/devices")
        assertThat(again.getHeader("X-DataTalks-Device-Secret")).isNull()
        assertThat(store.installId).isNotEqualTo(INSTALL_ID)
        assertThat(store.pendingIdentity).isNull()
    }

    @Test
    fun identifyVerified_sendsTheBodyAndReportsVerified() {
        val fixture = Contract.fixture("identify-verified")
        registerFirst(fixture)
        val body = fixture.requestBody(1)
        store.pendingIdentity = PendingIdentity.Identify(body.getString("external_id"), body.getString("email"), Contract.IDENTITY_TOKEN)
        server.enqueue(fixture.response(1))

        assertThat(sync.run()).isEqualTo(SyncOutcome.Done)

        fixture.assertSent(1, taken(), "IdentifyRequest")
        assertThat(store.pendingIdentity).isNull()
        assertThat(harness.identityResults.single().verified).isTrue()
        assertThat(harness.identityResults.single().errorCode).isNull()
    }

    @Test
    fun identifyUnverified_isAcceptedAsUnverified() {
        val fixture = Contract.fixture("identify-unverified")
        registerFirst(fixture)
        store.pendingIdentity = PendingIdentity.Identify(null, fixture.requestBody(1).getString("email"), null)
        server.enqueue(fixture.response(1))

        sync.run()

        fixture.assertSent(1, taken(), "IdentifyRequest")
        assertThat(harness.identityResults.single().verified).isFalse()
        assertThat(harness.identityResults.single().errorCode).isNull()
    }

    @Test
    fun identifyTokenRequired_isNotReplayed() = assertRefused("identify-token-required", "identity_token_required", null) { body ->
        PendingIdentity.Identify(body.getString("external_id"), null, null)
    }

    @Test
    fun identifyTokenExpired_isNotReplayed() = assertRefused("identify-token-expired", "identity_token_invalid", "expired") {
        PendingIdentity.Identify(null, null, Contract.IDENTITY_TOKEN)
    }

    @Test
    fun identifyClaimsMismatch_isNotReplayed() = assertRefused("identify-claims-mismatch", "identity_token_invalid", "claims_mismatch") { body ->
        PendingIdentity.Identify(body.getString("external_id"), null, Contract.IDENTITY_TOKEN)
    }

    @Test
    fun consentLogoutDelete_sendsEachOnce() {
        val fixture = Contract.fixture("consent-logout-delete")
        registerFirst(fixture)

        store.pendingOptIn = fixture.requestBody(1).getBoolean("marketing_opt_in")
        server.enqueue(fixture.response(1))
        sync.run()
        fixture.assertSent(1, taken(), "ConsentRequest")
        assertThat(store.pendingOptIn).isNull()

        store.pendingIdentity = PendingIdentity.Logout
        server.enqueue(fixture.response(2))
        sync.run()
        fixture.assertSent(2, taken())
        assertThat(store.pendingIdentity).isNull()

        val baseUrl = store.baseUrl
        store.wipe()
        store.pendingDelete = PendingDelete(Contract.APP_KEY, baseUrl, INSTALL_ID, Contract.DEVICE_SECRET)
        server.enqueue(fixture.response(3))
        assertThat(sync.run()).isEqualTo(SyncOutcome.Done)
        fixture.assertSent(3, taken())
        assertThat(store.pendingDelete).isNull()
    }

    @Test
    fun rateLimited_waitsForRetryAfter_AndSendsNothingUntilThen() {
        val fixture = Contract.fixture("rate-limited")
        registerFirst(fixture)

        val token = fixture.requestBody(2).getString("fcm_token") + "-changed"
        harness.lookup = PushValueLookup.Found(PushValue(token, PushValue.TYPE_FID))
        server.enqueue(fixture.response(2))
        assertThat(sync.run()).isEqualTo(SyncOutcome.RetryAfter(1))
        assertThat(store.pushValueChanged).isTrue()
        assertThat(server.requestCount).isEqualTo(2)

        assertThat(sync.run()).isInstanceOf(SyncOutcome.RetryAfter::class.java)
        assertThat(server.requestCount).isEqualTo(2)
    }

    private fun assertRefused(name: String, code: String, detail: String?, identity: (org.json.JSONObject) -> PendingIdentity) {
        val fixture = Contract.fixture(name)
        registerFirst(fixture)
        store.pendingIdentity = identity(fixture.requestBody(1))
        server.enqueue(fixture.response(1))

        assertThat(sync.run()).isEqualTo(SyncOutcome.Done)

        fixture.assertSent(1, taken(), "IdentifyRequest")
        assertThat(store.pendingIdentity).isNull()
        assertThat(harness.identityResults.single().errorCode).isEqualTo(code)
        assertThat(harness.identityResults.single().errorDetail).isEqualTo(detail)
        assertThat(store.installId).isEqualTo(INSTALL_ID)

        sync.run()
        assertThat(server.requestCount).isEqualTo(2)
    }

    @Test
    fun eventsReported_goWithTheSecret_AndAreForgotten_AlsoWhenTheSameCallComesBackAsDuplicates() {
        val fixture = Contract.fixture("events-reported")
        registerFirst(fixture)

        queueEventsOf(fixture.requestBody(1))
        server.enqueue(fixture.response(1))
        assertThat(sync.run()).isEqualTo(SyncOutcome.Done)
        fixture.assertSent(1, taken(), "EventsRequest")
        assertThat(store.hasEvents).isFalse()

        // After a lost response the same events are sent again; a `duplicate` result removes them just like `accepted`.
        queueEventsOf(fixture.requestBody(2))
        server.enqueue(fixture.response(2))
        assertThat(sync.run()).isEqualTo(SyncOutcome.Done)
        fixture.assertSent(2, taken(), "EventsRequest")
        assertThat(store.hasEvents).isFalse()
    }

    /** Queues the fixture's events as the SDK would: the same types and links, for a fixed push uid. */
    private fun queueEventsOf(body: org.json.JSONObject) {
        val events = body.getJSONArray("events")
        for (index in 0 until events.length()) {
            val event = events.getJSONObject(index)
            store.queueEvent(event.getString("type"), "8b0c6f7e-2d1a-4c3b-9a5e-0f1e2d3c4b5a", harness.now, event.optString("link").ifEmpty { null })
        }
    }

    private fun registerFirst(fixture: Fixture) {
        store.installId = INSTALL_ID
        harness.lookup = PushValueLookup.Found(PushValue(fixture.requestBody(0).getString("fcm_token"), fixture.requestBody(0).getString("fcm_token_type")))
        server.enqueue(fixture.response(0))
        check(sync.run() == SyncOutcome.Done)
        fixture.assertSent(0, taken(), "RegisterDeviceRequest")
    }

    private fun taken() = checkNotNull(server.takeRequest(5, TimeUnit.SECONDS)) { "The SDK sent nothing." }

    private fun created() = MockResponse().setResponseCode(201).setBody("""{"install_id":"$INSTALL_ID","device_secret":"${Contract.DEVICE_SECRET}"}""")

    private companion object {
        val REPLAYED = setOf(
            "config",
            "app-disabled",
            "key-invalid",
            "key-wrong-environment",
            "register-android-new",
            "register-android-token",
            "register-android-refresh",
            "register-known-install-without-secret",
            "device-auth-failed",
            "identify-verified",
            "identify-unverified",
            "identify-token-required",
            "identify-token-expired",
            "identify-claims-mismatch",
            "consent-logout-delete",
            "rate-limited",
            "events-reported",
        )

        val NOT_FOR_THE_ANDROID_SDK = setOf(
            // iOS, or a request this SDK never sends.
            "register-ios-sandbox",
            "register-platform-not-set-up",
            "register-token-transport-mismatch",
            "register-validation-failed",
            "events-implied-unknown-skipped",
            // Server routes, called by the customer's backend.
            "server-device-taken-over-by-sdk",
            "server-devices-delete",
            "server-devices-upsert",
        )
    }
}
