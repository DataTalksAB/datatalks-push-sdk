package se.datatalks.push

import android.app.NotificationManager
import android.content.Context
import com.google.common.truth.Truth.assertThat
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.QueueDispatcher
import okhttp3.mockwebserver.RecordedRequest
import org.json.JSONObject
import org.junit.After
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import se.datatalks.push.internal.AcceptedIdentity
import se.datatalks.push.internal.PendingDelete
import se.datatalks.push.internal.PendingIdentity
import se.datatalks.push.internal.PushEvent
import se.datatalks.push.internal.PushSync
import se.datatalks.push.internal.PushValue
import se.datatalks.push.internal.PushValueLookup
import se.datatalks.push.internal.SyncOutcome
import se.datatalks.push.internal.identityFingerprint
import java.util.concurrent.TimeUnit

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class PushSyncTest {
    private val harness = SyncHarness()
    private val server = harness.server
    private val store = harness.store
    private val sync = harness.sync

    @After
    fun stop() = harness.stop()

    @Test
    fun aNewInstall_generatesALowerCaseUuidV4() {
        server.enqueue(created())

        sync.run()

        val body = JSONObject(taken().body.readUtf8())
        assertThat(body.getString("install_id")).matches("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
        assertThat(body.getString("install_id")).isEqualTo(store.installId)
        assertThat(body.getString("platform")).isEqualTo("android")
    }

    @Test
    fun theDeviceMetadata_fitsTheContract() {
        server.enqueue(created())

        sync.run()

        Contract.assertFits("RegisterDeviceRequest", JSONObject(taken().body.readUtf8()))
    }

    @Test
    fun nothingIsSent_WhenNothingChanged_UntilTheNextDay() {
        registerOnce()

        assertThat(sync.isDue()).isFalse()
        sync.run()
        assertThat(server.requestCount).isEqualTo(1)

        harness.now += DAY_MILLIS
        assertThat(sync.isDue()).isTrue()
        server.enqueue(MockResponse().setResponseCode(200).setBody("""{"install_id":"$INSTALL_ID"}"""))
        sync.run()
        assertThat(server.requestCount).isEqualTo(2)
    }

    @Test
    fun aChangedPermission_registersAgain() {
        registerOnce()
        val manager = harness.context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        shadowOf(manager).setNotificationsEnabled(false)
        store.permissionAsked = true

        assertThat(sync.isDue()).isTrue()
        server.enqueue(MockResponse().setResponseCode(200).setBody("""{"install_id":"$INSTALL_ID"}"""))
        sync.run()
        taken()
        assertThat(JSONObject(taken().body.readUtf8()).getString("os_permission")).isEqualTo("denied")
    }

    @Test
    fun anAppMovingToFidMode_replacesItsTokenOnTheSameInstall() {
        harness.lookup = PushValueLookup.Found(PushValue("$FID:APA91bFIXTURE", PushValue.TYPE_TOKEN))
        registerOnce()
        val install = store.installId

        harness.lookup = PushValueLookup.Found(PushValue(FID, PushValue.TYPE_FID))
        server.enqueue(MockResponse().setResponseCode(200).setBody("""{"install_id":"$install"}"""))
        sync.run()

        taken()
        val body = JSONObject(taken().body.readUtf8())
        assertThat(body.getString("fcm_token")).isEqualTo(FID)
        assertThat(body.getString("fcm_token_type")).isEqualTo("fcm_fid")
        assertThat(body.getString("install_id")).isEqualTo(install)
    }

    @Test
    fun aRefusedRegistration_isNotRetriedTheSameDay() {
        server.enqueue(MockResponse().setResponseCode(400).setBody("""{"error":{"code":"validation_failed","message":"x"}}"""))

        assertThat(sync.run()).isEqualTo(SyncOutcome.Done)

        assertThat(sync.isDue()).isFalse()
        sync.run()
        assertThat(server.requestCount).isEqualTo(1)
    }

    @Test
    fun aServerError_backsOff_AndKeepsWhatIsToDo() {
        server.enqueue(MockResponse().setResponseCode(500).setBody("""{"error":{"code":"internal_error","message":"x"}}"""))

        assertThat(sync.run()).isEqualTo(SyncOutcome.Backoff)

        assertThat(sync.isDue()).isTrue()
        assertThat(store.deviceSecret).isNull()
    }

    @Test
    fun aNetworkError_backsOff() {
        server.shutdown()

        assertThat(sync.run()).isEqualTo(SyncOutcome.Backoff)
    }

    @Test
    fun aRetryAfter_isKept_UntilItHasPassed() {
        server.enqueue(MockResponse().setResponseCode(503).addHeader("Retry-After", "120").setBody("""{"error":{"code":"unavailable","message":"x"}}"""))

        assertThat(sync.run()).isEqualTo(SyncOutcome.RetryAfter(120))
        assertThat(sync.run()).isInstanceOf(SyncOutcome.RetryAfter::class.java)
        assertThat(server.requestCount).isEqualTo(1)

        harness.now += 121_000
        server.enqueue(created())
        assertThat(sync.run()).isEqualTo(SyncOutcome.Done)
    }

    @Test
    fun aRetryAfterThatIsMissing_getsADefault() {
        server.enqueue(MockResponse().setResponseCode(429).setBody("""{"error":{"code":"rate_limited","message":"x"}}"""))

        assertThat(sync.run()).isEqualTo(SyncOutcome.RetryAfter(60))
    }

    @Test
    fun noValueYet_backsOff_AndAnAppWithoutFirebaseDoesNot() {
        harness.lookup = PushValueLookup.TryLater
        assertThat(sync.run()).isEqualTo(SyncOutcome.Backoff)

        harness.lookup = PushValueLookup.NotConfigured
        assertThat(sync.run()).isEqualTo(SyncOutcome.Done)

        assertThat(server.requestCount).isEqualTo(0)
    }

    @Test
    fun aValueFirebaseCantReadRightNow_stillRegistersTheStoredOne() {
        store.updatePushValue(PushValue(FID, PushValue.TYPE_FID))
        harness.lookup = PushValueLookup.TryLater
        server.enqueue(created())

        assertThat(sync.run()).isEqualTo(SyncOutcome.Done)

        assertThat(JSONObject(taken().body.readUtf8()).getString("fcm_token")).isEqualTo(FID)
    }

    @Test
    fun anIdentifyBeforeTheFirstRegistration_goesAfterIt() {
        store.pendingIdentity = PendingIdentity.Identify("member-1001", null, null)
        server.enqueue(created())
        server.enqueue(MockResponse().setResponseCode(200).setBody("""{"identity_verified":false}"""))

        assertThat(sync.run()).isEqualTo(SyncOutcome.Done)

        assertThat(taken().path).isEqualTo("/v1/devices")
        val identify = taken()
        assertThat(identify.path).isEqualTo("/v1/devices/${store.installId}/identify")
        assertThat(identify.getHeader("X-DataTalks-Device-Secret")).isEqualTo(Contract.DEVICE_SECRET)
    }

    @Test
    fun anIdentifyWaits_WhileItsCallCantBeAnswered() {
        registerOnce()
        store.pendingIdentity = PendingIdentity.Identify("member-1001", null, null)
        server.enqueue(MockResponse().setResponseCode(503).addHeader("Retry-After", "1").setBody("""{"error":{"code":"unavailable","message":"x"}}"""))

        assertThat(sync.run()).isEqualTo(SyncOutcome.RetryAfter(1))

        assertThat(store.pendingIdentity).isNotNull()
        assertThat(harness.identityResults).isEmpty()
    }

    @Test
    fun anIdentify_isDropped_WhenTheInstallWasTheProblem_AndTheConsentIsNot() {
        registerOnce()
        store.pendingIdentity = PendingIdentity.Identify("member-1001", null, Contract.IDENTITY_TOKEN)
        store.pendingOptIn = false
        server.enqueue(MockResponse().setResponseCode(401).setBody("""{"error":{"code":"device_auth_failed","message":"x"}}"""))
        server.enqueue(created())
        server.enqueue(MockResponse().setResponseCode(204))

        assertThat(sync.run()).isEqualTo(SyncOutcome.Done)

        assertThat(store.pendingIdentity).isNull()
        assertThat(harness.identityResults.single().errorCode).isEqualTo("device_auth_failed")
        taken()
        assertThat(taken().path).endsWith("/identify")
        assertThat(taken().path).isEqualTo("/v1/devices")
        assertThat(taken().path).isEqualTo("/v1/devices/${store.installId}/consent")
        assertThat(store.pendingOptIn).isNull()
    }

    @Test
    fun anAcceptedIdentify_isRemembered_SoTheSameOneThatDaySendsNothing() {
        registerOnce()
        val identity = PendingIdentity.Identify("member-1001", "anna@example.com", null)
        store.pendingIdentity = identity
        server.enqueue(MockResponse().setResponseCode(200).setBody("""{"identity_verified":false}"""))

        sync.run()

        val today = harness.now / DAY_MILLIS
        taken()
        assertThat(taken().path).endsWith("/identify")
        assertThat(store.acceptedIdentity!!.day).isEqualTo(today)
        assertThat(store.repeatedAnswer(identity, today)).isFalse()
        assertThat(store.repeatedAnswer(identity, today + 1)).isNull()
        assertThat(store.repeatedAnswer(PendingIdentity.Identify("member-1002", "anna@example.com", null), today)).isNull()
        assertThat(store.repeatedAnswer(identity.copy(identityToken = Contract.IDENTITY_TOKEN), today)).isNull()
        assertThat(store.repeatedAnswer(PendingIdentity.Logout, today)).isNull()
    }

    @Test
    fun aVerifiedAnswer_isTheOneARepeatHears() {
        registerOnce()
        val identity = PendingIdentity.Identify("member-1001", null, Contract.IDENTITY_TOKEN)
        store.pendingIdentity = identity
        server.enqueue(MockResponse().setResponseCode(200).setBody("""{"identity_verified":true}"""))

        sync.run()

        assertThat(store.repeatedAnswer(identity, harness.now / DAY_MILLIS)).isTrue()
    }

    @Test
    fun theAcceptedIdentity_isNoReason_ToSkipWhileAnotherCallWaits() {
        registerOnce()
        val identity = PendingIdentity.Identify("member-1001", null, null)
        store.acceptedIdentity = AcceptedIdentity(identityFingerprint(store.installId!!, identity), harness.now / DAY_MILLIS, false)
        store.pendingIdentity = PendingIdentity.Logout

        assertThat(store.repeatedAnswer(identity, harness.now / DAY_MILLIS)).isNull()
    }

    @Test
    fun aRefusedIdentify_andALogout_forgetTheAcceptedIdentity() {
        registerOnce()
        val identity = PendingIdentity.Identify("member-1001", null, null)
        store.acceptedIdentity = AcceptedIdentity(identityFingerprint(store.installId!!, identity), harness.now / DAY_MILLIS, false)
        store.pendingIdentity = identity
        server.enqueue(MockResponse().setResponseCode(400).setBody("""{"error":{"code":"validation_failed","message":"x"}}"""))

        sync.run()

        assertThat(store.acceptedIdentity).isNull()

        store.acceptedIdentity = AcceptedIdentity(identityFingerprint(store.installId!!, identity), harness.now / DAY_MILLIS, false)
        store.pendingIdentity = PendingIdentity.Logout
        server.enqueue(MockResponse().setResponseCode(204))

        sync.run()

        assertThat(store.acceptedIdentity).isNull()
    }

    @Test
    fun aTokenOnlyIdentify_isNeverSkipped() {
        registerOnce()
        val identity = PendingIdentity.Identify(null, null, Contract.IDENTITY_TOKEN)
        store.pendingIdentity = identity
        server.enqueue(MockResponse().setResponseCode(200).setBody("""{"identity_verified":true}"""))

        sync.run()

        assertThat(store.repeatedAnswer(identity, harness.now / DAY_MILLIS)).isNull()
    }

    @Test
    fun aSuccessWithoutTheServicesAnswer_isNotRemembered() {
        registerOnce()
        store.pendingIdentity = PendingIdentity.Identify("member-1001", null, null)
        server.enqueue(MockResponse().setResponseCode(200).setBody("{}"))

        sync.run()

        assertThat(store.acceptedIdentity).isNull()
    }

    @Test
    fun aNewAppKey_forgetsTheAcceptedIdentity() {
        registerOnce()
        val identity = PendingIdentity.Identify("member-1001", null, null)
        store.acceptedIdentity = AcceptedIdentity(identityFingerprint(store.installId!!, identity), harness.now / DAY_MILLIS, false)

        store.replaceAppKey("dtpk_prd_Fixture0AppKey000000000000000000")

        assertThat(store.acceptedIdentity).isNull()
    }

    @Test
    fun aLogoutMadeDuringTheIdentify_goesNext() {
        registered()
        store.pendingIdentity = PendingIdentity.Identify("member-1001", null, null)
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                // The app logs out while the identify is in flight.
                store.pendingIdentity = PendingIdentity.Logout
                return MockResponse().setResponseCode(200).setBody("""{"identity_verified":false}""")
            }
        }

        sync.run()

        assertThat(taken().path).endsWith("/identify")
        assertThat(store.pendingIdentity).isEqualTo(PendingIdentity.Logout)
        assertThat(store.acceptedIdentity).isNotNull()
        assertThat(sync.isDue()).isTrue()

        server.dispatcher = QueueDispatcher()
        server.enqueue(MockResponse().setResponseCode(204))
        sync.run()

        assertThat(taken().path).endsWith("/logout")
        assertThat(store.pendingIdentity).isNull()
        assertThat(store.acceptedIdentity).isNull()
    }

    @Test
    fun anIdentifyThatRepeatsTodaysAnswer_isNotQueued() {
        registerOnce()
        val identity = PendingIdentity.Identify("member-1001", null, null)
        store.acceptedIdentity = AcceptedIdentity(identityFingerprint(store.installId!!, identity), harness.now / DAY_MILLIS, true)

        assertThat(store.queueIdentity(identity, harness.now / DAY_MILLIS)).isTrue()
        assertThat(store.pendingIdentity).isNull()

        assertThat(store.queueIdentity(PendingIdentity.Logout, harness.now / DAY_MILLIS)).isNull()
        assertThat(store.pendingIdentity).isEqualTo(PendingIdentity.Logout)
    }

    @Test
    fun aChangeOfRequireVerifiedIdentity_forgetsTheAcceptedIdentity() {
        registerOnce()
        val identity = PendingIdentity.Identify("member-1001", null, null)
        val accepted = AcceptedIdentity(identityFingerprint(store.installId!!, identity), harness.now / DAY_MILLIS, false)
        store.acceptedIdentity = accepted

        store.requireVerifiedIdentity = store.requireVerifiedIdentity
        assertThat(store.acceptedIdentity).isEqualTo(accepted)

        store.requireVerifiedIdentity = !store.requireVerifiedIdentity
        assertThat(store.acceptedIdentity).isNull()
    }

    @Test
    fun aNewInstall_forgetsTheAcceptedIdentity() {
        registerOnce()
        val identity = PendingIdentity.Identify("member-1001", null, null)
        store.acceptedIdentity = AcceptedIdentity(identityFingerprint(store.installId!!, identity), harness.now / DAY_MILLIS, false)

        store.dropInstall()

        assertThat(store.acceptedIdentity).isNull()
    }

    @Test
    fun aRepeatingConflict_endsInBackoff_NotALoop() {
        repeat(3) { server.enqueue(MockResponse().setResponseCode(409).setBody("""{"error":{"code":"install_id_conflict","message":"x"}}""")) }

        assertThat(sync.run()).isEqualTo(SyncOutcome.Backoff)

        assertThat(server.requestCount).isEqualTo(3)
    }

    @Test
    fun anAppNotSetUpForAndroid_registersNothing() {
        store.configExpiresAt = 0
        server.enqueue(MockResponse().setResponseCode(200).setBody("""{"require_verified_identity":false,"platforms":{"ios":{"transport":"apns"}},"refresh_after_seconds":3600}"""))

        assertThat(sync.run()).isEqualTo(SyncOutcome.Done)

        assertThat(server.requestCount).isEqualTo(1)
        assertThat(sync.stopped).isTrue()
    }

    @Test
    fun theConfig_isCachedForAsLongAsItSays() {
        store.configExpiresAt = 0
        server.enqueue(MockResponse().setResponseCode(200).setBody("""{"require_verified_identity":true,"platforms":{"android":{"transport":"fcm"}},"refresh_after_seconds":600}"""))
        server.enqueue(created())
        sync.run()
        assertThat(server.requestCount).isEqualTo(2)
        assertThat(store.configExpiresAt).isEqualTo(harness.now + 600_000)

        store.pushValueChanged = true
        server.enqueue(MockResponse().setResponseCode(200).setBody("""{"install_id":"$INSTALL_ID"}"""))
        sync.run()
        assertThat(server.requestCount).isEqualTo(3)
    }

    @Test
    fun aPendingDelete_survivesAFailure_AndGoesOnce() {
        val baseUrl = store.baseUrl
        store.wipe()
        store.pendingDelete = PendingDelete(Contract.APP_KEY, baseUrl, INSTALL_ID, Contract.DEVICE_SECRET)
        server.enqueue(MockResponse().setResponseCode(500).setBody("""{"error":{"code":"internal_error","message":"x"}}"""))
        assertThat(sync.run()).isEqualTo(SyncOutcome.Backoff)
        assertThat(store.pendingDelete).isNotNull()

        server.enqueue(MockResponse().setResponseCode(204))
        assertThat(sync.run()).isEqualTo(SyncOutcome.Done)
        assertThat(store.pendingDelete).isNull()
        assertThat(sync.isDue()).isFalse()
    }

    @Test
    fun theBackoff_doublesUpToAnHour_WithSomeSpread() {
        assertThat(PushSync.backoffSeconds(0, spread = 1.0)).isEqualTo(30)
        assertThat(PushSync.backoffSeconds(1, spread = 1.0)).isEqualTo(60)
        assertThat(PushSync.backoffSeconds(0, spread = 0.0)).isEqualTo(24)
        assertThat(PushSync.backoffSeconds(7, spread = 1.0)).isEqualTo(3600)
        assertThat(PushSync.backoffSeconds(5000, spread = 1.0)).isEqualTo(3600)
    }

    @Test
    fun events_goAfterTheRegistration_WithTheSecret_AndAreForgottenOnceAnswered() {
        registered()
        store.queueEvent(PushEvent.DELIVERY, UID, harness.now - 60_000)
        store.queueEvent(PushEvent.CLICK, UID, harness.now, "https://example.com/tickets")
        assertThat(sync.isDue()).isTrue()
        server.enqueue(accepted(2))

        assertThat(sync.run()).isEqualTo(SyncOutcome.Done)

        val sent = taken()
        assertThat(sent.path).isEqualTo("/v1/devices/${store.installId}/events")
        assertThat(sent.getHeader("X-DataTalks-Device-Secret")).isEqualTo(Contract.DEVICE_SECRET)
        val body = JSONObject(sent.body.readUtf8())
        Contract.assertFits("EventsRequest", body)
        val events = body.getJSONArray("events")
        assertThat(events.getJSONObject(0).getString("type")).isEqualTo("delivery")
        assertThat(events.getJSONObject(0).getString("occurred_at")).isEqualTo("2027-01-15T07:59:00.000Z")
        assertThat(events.getJSONObject(1).getString("link")).isEqualTo("https://example.com/tickets")
        assertThat(store.hasEvents).isFalse()
        assertThat(sync.isDue()).isFalse()
    }

    @Test
    fun events_waitForAnInstall() {
        harness.lookup = PushValueLookup.TryLater
        store.queueEvent(PushEvent.OPEN, UID, harness.now)

        sync.run()

        assertThat(server.requestCount).isEqualTo(0)
        assertThat(store.hasEvents).isTrue()
    }

    @Test
    fun aBusyService_keepsTheEvents_ForTheSameCallLater() {
        registered()
        store.queueEvent(PushEvent.OPEN, UID, harness.now)
        val eventId = store.pendingEvents(harness.now).single().eventId
        server.enqueue(MockResponse().setResponseCode(503).setHeader("Retry-After", "5").setBody("""{"error":{"code":"unavailable","message":"x"}}"""))

        assertThat(sync.run()).isEqualTo(SyncOutcome.RetryAfter(5))

        assertThat(store.pendingEvents(harness.now).single().eventId).isEqualTo(eventId)
    }

    @Test
    fun anUnknownInstall_dropsItsEvents_AndRegistersANewOne() {
        registered()
        store.queueEvent(PushEvent.OPEN, UID, harness.now)
        server.enqueue(MockResponse().setResponseCode(401).setBody("""{"error":{"code":"device_auth_failed","message":"x"}}"""))
        server.enqueue(created())

        assertThat(sync.run()).isEqualTo(SyncOutcome.Done)

        taken()
        assertThat(taken().path).isEqualTo("/v1/devices")
        assertThat(store.hasEvents).isFalse()
    }

    @Test
    fun manyEvents_goInCallsOf50() {
        registered()
        repeat(60) { store.queueEvent(PushEvent.DELIVERY, "8b0c6f7e-2d1a-4c3b-9a5e-0f1e2d3c4b${it.toString().padStart(2, '0')}", harness.now) }
        store.queueEvent(PushEvent.CLICK, UID, harness.now, "https://example.com/" + "a".repeat(2_000))
        server.enqueue(accepted(50))
        server.enqueue(accepted(11))

        assertThat(sync.run()).isEqualTo(SyncOutcome.Done)

        val calls = (1..server.requestCount - 1).map { taken() }
        assertThat(calls.map { JSONObject(it.body.clone().readUtf8()).getJSONArray("events").length() }).containsExactly(50, 11).inOrder()
        assertThat(calls.maxOf { it.bodySize }).isAtMost(8_192L)
        assertThat(store.hasEvents).isFalse()
    }

    @Test
    fun longLinks_goInCallsThatFitTheBodyLimit() {
        registered()
        repeat(8) { store.queueEvent(PushEvent.CLICK, UID, harness.now, "https://example.com/" + "a".repeat(2_000)) }
        server.enqueue(accepted(3))
        server.enqueue(accepted(3))
        server.enqueue(accepted(2))

        assertThat(sync.run()).isEqualTo(SyncOutcome.Done)

        val calls = (1..server.requestCount - 1).map { taken() }
        assertThat(calls.map { JSONObject(it.body.clone().readUtf8()).getJSONArray("events").length() }).containsExactly(3, 3, 2).inOrder()
        assertThat(calls.maxOf { it.bodySize }).isAtMost(8_000L)
        assertThat(store.hasEvents).isFalse()
    }

    @Test
    fun aSuccessWithoutResults_keepsTheEvents() {
        registered()
        store.queueEvent(PushEvent.OPEN, UID, harness.now)
        server.enqueue(MockResponse().setResponseCode(200).setBody("<html>Sign in to the Wi-Fi</html>"))

        assertThat(sync.run()).isEqualTo(SyncOutcome.Backoff)

        assertThat(server.requestCount).isEqualTo(2)
        assertThat(store.hasEvents).isTrue()
    }

    @Test
    fun anIngressWithoutTheEventsRoute_keepsTheEvents_ForTheOneThatTakesThem() {
        registered()
        store.queueEvent(PushEvent.OPEN, UID, harness.now)
        val eventId = store.pendingEvents(harness.now).single().eventId
        server.enqueue(MockResponse().setResponseCode(404))

        assertThat(sync.run()).isEqualTo(SyncOutcome.Backoff)
        assertThat(store.pendingEvents(harness.now).single().eventId).isEqualTo(eventId)

        server.enqueue(accepted(1))
        assertThat(sync.run()).isEqualTo(SyncOutcome.Done)
        taken()
        val again = JSONObject(taken().body.readUtf8()).getJSONArray("events")
        assertThat(again.getJSONObject(0).getString("event_id")).isEqualTo(eventId)
        assertThat(store.hasEvents).isFalse()
    }

    @Test
    fun aRefusedEventsCall_dropsTheEvents() {
        registered()
        store.queueEvent(PushEvent.OPEN, UID, harness.now)
        server.enqueue(MockResponse().setResponseCode(400).setBody("""{"error":{"code":"validation_failed","message":"x"}}"""))

        assertThat(sync.run()).isEqualTo(SyncOutcome.Done)

        assertThat(server.requestCount).isEqualTo(2)
        assertThat(store.hasEvents).isFalse()
        assertThat(sync.isDue()).isFalse()
    }

    @Test
    fun events_waitWhileTheInstallHasNoSecret() {
        registered()
        store.queueEvent(PushEvent.OPEN, UID, harness.now)
        assertThat(sync.isDue()).isTrue()

        store.deviceSecret = null

        assertThat(sync.isDue()).isFalse()
    }

    private fun registerOnce() {
        server.enqueue(created())
        check(sync.run() == SyncOutcome.Done)
    }

    /** Registers, then takes the registration request off the server. */
    private fun registered() {
        registerOnce()
        taken()
    }

    private fun accepted(count: Int) = MockResponse().setResponseCode(202)
        .setBody("""{"results":[${(0 until count).joinToString(",") { """{"index":$it,"result":"accepted"}""" }}]}""")

    private fun taken() = checkNotNull(server.takeRequest(5, TimeUnit.SECONDS)) { "The SDK sent nothing." }

    private fun created() = MockResponse().setResponseCode(201).setBody("""{"install_id":"$INSTALL_ID","device_secret":"${Contract.DEVICE_SECRET}"}""")

    private companion object {
        const val DAY_MILLIS = 86_400_000L
        const val UID = "8b0c6f7e-2d1a-4c3b-9a5e-0f1e2d3c4b5a"
    }
}
