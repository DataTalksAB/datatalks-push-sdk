import XCTest
@testable import DataTalksPush

final class PushSyncTests: XCTestCase {
    private static let day: TimeInterval = 86400
    private static let uid = "8b0c6f7e-2d1a-4c3b-9a5e-0f1e2d3c4b5a"
    private static let fcmToken = "fWm3x0Fixture:APA91bFixtureRegistrationToken"

    private var harness: SyncHarness!
    private var store: PushStore { harness.store }
    private var sync: PushSync { harness.sync }

    override func setUp() {
        harness = SyncHarness()
    }

    func testANewInstallGeneratesALowerCaseUuidV4() {
        StubServer.enqueue(.created())

        _ = sync.run()

        let installId = StubServer.requests[0].json["install_id"] as? String
        XCTAssertNotNil(installId?.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", options: .regularExpression))
        XCTAssertEqual(installId, store.installId)
    }

    func testARegistrationFitsTheContract() {
        StubServer.enqueue(.created())

        _ = sync.run()

        let body = StubServer.requests[0].json
        Contract.assertFits("RegisterDeviceRequest", body)
        XCTAssertEqual(body["platform"] as? String, "ios")
        XCTAssertEqual(body["apns_token"] as? String, Contract.apnsToken)
        XCTAssertNil(body["fcm_token"])
    }

    func testTheRealDeviceFactsFitTheContract() {
        var body: [String: Any] = SystemFacts().metadata()
        body["install_id"] = Contract.installId
        body["platform"] = "ios"

        Contract.assertFits("RegisterDeviceRequest", body)
        XCTAssertEqual(body["device_manufacturer"] as? String, "Apple")
        XCTAssertNotNil(body["device_model"])
    }

    func testNothingIsSentWhenNothingChangedUntilTheNextDay() {
        registerOnce()

        XCTAssertFalse(sync.isDue())
        _ = sync.run()
        XCTAssertEqual(StubServer.requests.count, 1)

        harness.now += Self.day
        XCTAssertTrue(sync.isDue())
        StubServer.enqueue(.updated())
        _ = sync.run()
        XCTAssertEqual(StubServer.requests.count, 2)
    }

    func testAChangedPermissionRegistersAgain() {
        registerOnce()

        harness.facts.currentPermission = "denied"

        XCTAssertTrue(sync.isDue())
        StubServer.enqueue(.updated())
        _ = sync.run()
        XCTAssertEqual(StubServer.requests[1].json["os_permission"] as? String, "denied")
    }

    func testNoTokenYetMeansNothingIsSent() {
        let fresh = SyncHarness()
        fresh.store.wipe()
        fresh.store.appKey = Contract.appKey
        fresh.store.baseUrl = "https://ingress.example.test/v1"
        fresh.store.configExpiresAt = .greatestFiniteMagnitude
        fresh.store.pendingIdentity = .identify(externalId: "member-1001", email: nil, identityToken: nil)

        XCTAssertEqual(fresh.sync.run(), .done)

        XCTAssertEqual(StubServer.requests.count, 0)
        XCTAssertNotNil(fresh.store.pendingIdentity, "It goes once there is an install.")
    }

    func testARefusedRegistrationIsNotRetriedTheSameDay() {
        StubServer.enqueue(.error(400, "validation_failed"))

        XCTAssertEqual(sync.run(), .done)

        XCTAssertFalse(sync.isDue())
        _ = sync.run()
        XCTAssertEqual(StubServer.requests.count, 1)
    }

    func testAServerErrorBacksOffAndKeepsWhatIsToDo() {
        StubServer.enqueue(.error(500, "internal_error"))

        XCTAssertEqual(sync.run(), .backoff)

        XCTAssertTrue(sync.isDue())
        XCTAssertNil(store.deviceSecret)
    }

    func testANetworkErrorBacksOff() {
        XCTAssertEqual(sync.run(), .backoff)
    }

    func testARetryAfterIsKeptUntilItHasPassed() {
        StubServer.enqueue(.error(503, "unavailable", retryAfter: "120"))

        XCTAssertEqual(sync.run(), .retryAfter(120))
        guard case .retryAfter = sync.run() else { return XCTFail("It should still wait.") }
        XCTAssertEqual(StubServer.requests.count, 1)

        harness.now += 121
        StubServer.enqueue(.created())
        XCTAssertEqual(sync.run(), .done)
    }

    func testARetryAfterThatIsMissingGetsADefault() {
        StubServer.enqueue(.error(429, "rate_limited"))

        XCTAssertEqual(sync.run(), .retryAfter(60))
    }

    func testAnIdentifyBeforeTheFirstRegistrationGoesAfterIt() {
        store.pendingIdentity = .identify(externalId: "member-1001", email: nil, identityToken: nil)
        StubServer.enqueue(.created())
        StubServer.enqueue(StubResponse(status: 200, body: Data(#"{"identity_verified":false}"#.utf8)))

        XCTAssertEqual(sync.run(), .done)

        XCTAssertEqual(StubServer.requests[0].path, "/v1/devices")
        XCTAssertEqual(StubServer.requests[1].path, "/v1/devices/\(store.installId!)/identify")
        XCTAssertEqual(StubServer.requests[1].headers["X-DataTalks-Device-Secret"], Contract.deviceSecret)
    }

    func testAnIdentifyWaitsWhileItsCallCantBeAnswered() {
        registerOnce()
        store.pendingIdentity = .identify(externalId: "member-1001", email: nil, identityToken: nil)
        StubServer.enqueue(.error(503, "unavailable", retryAfter: "1"))

        XCTAssertEqual(sync.run(), .retryAfter(1))

        XCTAssertNotNil(store.pendingIdentity)
        XCTAssertEqual(harness.identityResults.count, 0)
    }

    func testAnIdentifyIsDroppedWhenTheInstallWasTheProblemAndTheConsentIsNot() {
        registerOnce()
        store.pendingIdentity = .identify(externalId: "member-1001", email: nil, identityToken: Contract.identityToken)
        store.pendingOptIn = false
        StubServer.enqueue(.error(401, "device_auth_failed"))
        StubServer.enqueue(.created())
        StubServer.enqueue(StubResponse(status: 204))

        XCTAssertEqual(sync.run(), .done)

        XCTAssertNil(store.pendingIdentity)
        XCTAssertEqual(harness.identityResults[0].errorCode, "device_auth_failed")
        XCTAssertTrue(StubServer.requests[1].path.hasSuffix("/identify"))
        XCTAssertEqual(StubServer.requests[2].path, "/v1/devices")
        XCTAssertEqual(StubServer.requests[3].path, "/v1/devices/\(store.installId!)/consent")
        XCTAssertNil(store.pendingOptIn)
    }

    func testARepeatingConflictEndsInBackoffNotALoop() {
        for _ in 0 ..< 3 { StubServer.enqueue(.error(409, "install_id_conflict")) }

        XCTAssertEqual(sync.run(), .backoff)

        XCTAssertEqual(StubServer.requests.count, 3)
    }

    func testAnAppNotSetUpForIosRegistersNothing() {
        store.configExpiresAt = 0
        StubServer.enqueue(StubResponse(status: 200, body: Data(#"{"require_verified_identity":false,"platforms":{"android":{"transport":"fcm"}},"refresh_after_seconds":3600}"#.utf8)))

        XCTAssertEqual(sync.run(), .done)

        XCTAssertEqual(StubServer.requests.count, 1)
        XCTAssertTrue(sync.stopped)
    }

    func testAnIosAppThatSendsThroughFcmRegistersTheFcmToken() {
        store.configExpiresAt = 0
        _ = store.updateFcmToken(Self.fcmToken)
        StubServer.enqueue(Self.config(transport: "fcm"))
        StubServer.enqueue(.created())

        XCTAssertEqual(sync.run(), .done)

        let body = StubServer.requests[1].json
        Contract.assertFits("RegisterDeviceRequest", body)
        XCTAssertEqual(body["platform"] as? String, "ios")
        XCTAssertEqual(body["fcm_token"] as? String, Self.fcmToken)
        XCTAssertEqual(body["fcm_token_type"] as? String, "fcm_token")
        XCTAssertNil(body["apns_token"])
        XCTAssertFalse(sync.isDue())
    }

    func testThroughFcmNothingIsRegisteredUntilTheAppPassesTheToken() {
        store.configExpiresAt = 0
        StubServer.enqueue(Self.config(transport: "fcm"))

        XCTAssertEqual(sync.run(), .done)

        XCTAssertEqual(StubServer.requests.count, 1)
        XCTAssertFalse(sync.stopped)
        XCTAssertTrue(sync.isDue())

        XCTAssertTrue(store.updateFcmToken(Self.fcmToken))
        StubServer.enqueue(.created())
        XCTAssertEqual(sync.run(), .done)
        XCTAssertEqual(StubServer.requests[1].json["fcm_token"] as? String, Self.fcmToken)
    }

    func testMovingTheAppToFcmRegistersAgainWithTheFcmToken() {
        registerOnce()
        _ = store.updateFcmToken(Self.fcmToken)
        XCTAssertFalse(sync.isDue())

        store.configExpiresAt = 0
        StubServer.enqueue(Self.config(transport: "fcm"))
        StubServer.enqueue(.updated())
        XCTAssertEqual(sync.run(), .done)

        XCTAssertEqual(StubServer.requests.count, 3)
        XCTAssertEqual(StubServer.requests[2].json["fcm_token"] as? String, Self.fcmToken)
        XCTAssertNil(StubServer.requests[2].json["apns_token"])
    }

    func testTheConfigIsCachedForAsLongAsItSays() {
        store.configExpiresAt = 0
        StubServer.enqueue(StubResponse(status: 200, body: Data(#"{"require_verified_identity":true,"platforms":{"ios":{"transport":"apns"}},"refresh_after_seconds":600}"#.utf8)))
        StubServer.enqueue(.created())
        _ = sync.run()
        XCTAssertEqual(StubServer.requests.count, 2)
        XCTAssertEqual(store.configExpiresAt, harness.now + 600)

        store.tokenChanged = true
        StubServer.enqueue(.updated())
        _ = sync.run()
        XCTAssertEqual(StubServer.requests.count, 3)
    }

    func testAPendingDeleteSurvivesAFailureAndGoesOnce() {
        let baseUrl = store.baseUrl
        store.wipe()
        store.pendingDelete = PendingDelete(appKey: Contract.appKey, baseUrl: baseUrl, installId: Contract.installId, deviceSecret: Contract.deviceSecret)
        StubServer.enqueue(.error(500, "internal_error"))
        XCTAssertEqual(sync.run(), .backoff)
        XCTAssertNotNil(store.pendingDelete)

        StubServer.enqueue(StubResponse(status: 204))
        XCTAssertEqual(sync.run(), .done)
        XCTAssertNil(store.pendingDelete)
        XCTAssertFalse(sync.isDue())
    }

    func testEventsGoAfterTheRegistrationWithTheSecretAndAreForgottenOnceAnswered() {
        registerOnce()
        store.queueEvent(PushEvent.open, uid: Self.uid, occurredAt: harness.now - 60)
        store.queueEvent(PushEvent.click, uid: Self.uid, occurredAt: harness.now - 60, link: "https://example.com/tickets")
        XCTAssertTrue(sync.isDue())
        StubServer.enqueue(Self.accepted(2))

        XCTAssertEqual(sync.run(), .done)

        let sent = StubServer.requests[1]
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(sent.path, "/v1/devices/\(store.installId!)/events")
        XCTAssertEqual(sent.headers["X-DataTalks-Device-Secret"], Contract.deviceSecret)
        Contract.assertFits("EventsRequest", sent.json)
        let events = sent.json["events"] as? [[String: Any]] ?? []
        XCTAssertEqual(events.map { $0["type"] as? String }, ["open", "click"])
        XCTAssertEqual(events.first?["occurred_at"] as? String, "2027-01-15T07:59:00.000Z")
        XCTAssertNil(events.first?["link"])
        XCTAssertEqual(events.last?["link"] as? String, "https://example.com/tickets")
        XCTAssertFalse(store.hasEvents)
        XCTAssertFalse(sync.isDue())
    }

    func testEventsWaitForAnInstall() {
        store.wipe()
        store.appKey = Contract.appKey
        store.baseUrl = "https://ingress.example.test/v1"
        store.configExpiresAt = .greatestFiniteMagnitude
        store.queueEvent(PushEvent.open, uid: Self.uid, occurredAt: harness.now)

        XCTAssertEqual(sync.run(), .done)

        XCTAssertEqual(StubServer.requests.count, 0)
        XCTAssertTrue(store.hasEvents)
    }

    func testABusyServiceKeepsTheEventsForTheSameCallLater() {
        registerOnce()
        store.queueEvent(PushEvent.open, uid: Self.uid, occurredAt: harness.now)
        let eventId = store.pendingEvents(now: harness.now)[0].eventId
        StubServer.enqueue(.error(503, "unavailable", retryAfter: "5"))

        XCTAssertEqual(sync.run(), .retryAfter(5))
        XCTAssertEqual(store.pendingEvents(now: harness.now).map(\.eventId), [eventId])

        harness.now += 6
        StubServer.enqueue(Self.accepted(1))
        XCTAssertEqual(sync.run(), .done)
        XCTAssertEqual((StubServer.requests[2].json["events"] as? [[String: Any]])?.first?["event_id"] as? String, eventId)
        XCTAssertFalse(store.hasEvents)
    }

    func testARefusedCallIsNotSentAgain() {
        registerOnce()
        store.queueEvent(PushEvent.open, uid: Self.uid, occurredAt: harness.now)
        StubServer.enqueue(.error(400, "validation_failed"))

        XCTAssertEqual(sync.run(), .done)

        XCTAssertFalse(store.hasEvents)
        XCTAssertFalse(sync.isDue())
    }

    func testAnIngressWithoutTheEventsRouteKeepsTheEventsForTheOneThatTakesThem() {
        registerOnce()
        store.queueEvent(PushEvent.open, uid: Self.uid, occurredAt: harness.now)
        let eventId = store.pendingEvents(now: harness.now)[0].eventId
        StubServer.enqueue(StubResponse(status: 404, body: Data()))

        XCTAssertEqual(sync.run(), .backoff)
        XCTAssertEqual(store.pendingEvents(now: harness.now).map(\.eventId), [eventId])

        StubServer.enqueue(Self.accepted(1))
        XCTAssertEqual(sync.run(), .done)
        XCTAssertEqual((StubServer.requests[2].json["events"] as? [[String: Any]])?.first?["event_id"] as? String, eventId)
        XCTAssertFalse(store.hasEvents)
    }

    func testAnUnknownInstallDropsItsEventsAndRegistersANewOne() {
        registerOnce()
        store.queueEvent(PushEvent.open, uid: Self.uid, occurredAt: harness.now)
        StubServer.enqueue(.error(401, "device_auth_failed"))
        StubServer.enqueue(.created())

        XCTAssertEqual(sync.run(), .done)

        XCTAssertTrue(StubServer.requests[1].path.hasSuffix("/events"))
        XCTAssertEqual(StubServer.requests[2].path, "/v1/devices")
        XCTAssertNil(StubServer.requests[2].headers["X-DataTalks-Device-Secret"])
        XCTAssertEqual(StubServer.requests.count, 3)
        XCTAssertFalse(store.hasEvents)
    }

    func testManyEventsGoInCallsOf50() {
        registerOnce()
        for index in 0 ..< 60 {
            store.queueEvent(PushEvent.open, uid: String(format: "8b0c6f7e-2d1a-4c3b-9a5e-0f1e2d3c4b%02d", index), occurredAt: harness.now)
        }
        store.queueEvent(PushEvent.click, uid: Self.uid, occurredAt: harness.now, link: "https://example.com/" + String(repeating: "a", count: 2000))
        StubServer.enqueue(Self.accepted(50))
        StubServer.enqueue(Self.accepted(11))

        XCTAssertEqual(sync.run(), .done)

        let calls = Array(StubServer.requests.dropFirst())
        XCTAssertEqual(calls.map { ($0.json["events"] as? [[String: Any]])?.count ?? 0 }, [50, 11])
        for call in calls {
            XCTAssertLessThanOrEqual(call.body?.count ?? 0, 8192)
            Contract.assertFits("EventsRequest", call.json)
        }
        XCTAssertFalse(store.hasEvents)
    }

    func testLongLinksGoInCallsThatFitTheBodyLimit() {
        registerOnce()
        for _ in 0 ..< 8 {
            store.queueEvent(PushEvent.click, uid: Self.uid, occurredAt: harness.now, link: "https://example.com/" + String(repeating: "a", count: 2000))
        }
        StubServer.enqueue(Self.accepted(3))
        StubServer.enqueue(Self.accepted(3))
        StubServer.enqueue(Self.accepted(2))

        XCTAssertEqual(sync.run(), .done)

        let calls = Array(StubServer.requests.dropFirst())
        XCTAssertEqual(calls.map { ($0.json["events"] as? [[String: Any]])?.count ?? 0 }, [3, 3, 2])
        for call in calls {
            XCTAssertLessThanOrEqual(call.body?.count ?? 0, 8000)
        }
        XCTAssertFalse(store.hasEvents)
    }

    func testASuccessWithoutResultsKeepsTheEvents() {
        registerOnce()
        store.queueEvent(PushEvent.open, uid: Self.uid, occurredAt: harness.now)
        StubServer.enqueue(StubResponse(status: 200, body: Data("<html>Sign in to the Wi-Fi</html>".utf8)))

        XCTAssertEqual(sync.run(), .backoff)

        XCTAssertEqual(StubServer.requests.count, 2)
        XCTAssertTrue(store.hasEvents)
    }

    func testEventsWaitWhileTheInstallHasNoSecret() {
        registerOnce()
        store.queueEvent(PushEvent.open, uid: Self.uid, occurredAt: harness.now)
        XCTAssertTrue(sync.isDue())

        store.deviceSecret = nil

        XCTAssertFalse(sync.isDue())
    }

    func testTheBackoffDoublesUpToAnHourWithSomeSpread() {
        XCTAssertEqual(PushSync.backoffSeconds(attempt: 0, spread: 1), 30)
        XCTAssertEqual(PushSync.backoffSeconds(attempt: 1, spread: 1), 60)
        XCTAssertEqual(PushSync.backoffSeconds(attempt: 0, spread: 0), 24)
        XCTAssertEqual(PushSync.backoffSeconds(attempt: 7, spread: 1), 3600)
        XCTAssertEqual(PushSync.backoffSeconds(attempt: 5000, spread: 1), 3600)
    }

    func testAnAcceptedIdentifyIsRememberedSoTheSameOneThatDaySendsNothing() {
        registerOnce()
        let identity = PendingIdentity.identify(externalId: "member-1001", email: "anna@example.com", identityToken: nil)
        store.pendingIdentity = identity
        StubServer.enqueue(StubResponse(status: 200, body: Data(#"{"identity_verified":false}"#.utf8)))

        _ = sync.run()

        let today = Int(harness.now / Self.day)
        XCTAssertEqual(StubServer.requests.last?.path, "/v1/devices/\(store.installId!)/identify")
        XCTAssertEqual(store.acceptedIdentity?.day, today)
        XCTAssertEqual(store.repeatedAnswer(identity, day: today), false)
        XCTAssertNil(store.repeatedAnswer(identity, day: today + 1))
        XCTAssertNil(store.repeatedAnswer(.identify(externalId: "member-1002", email: "anna@example.com", identityToken: nil), day: today))
        XCTAssertNil(store.repeatedAnswer(.identify(externalId: "member-1001", email: "anna@example.com", identityToken: Contract.identityToken), day: today))
        XCTAssertNil(store.repeatedAnswer(.logout, day: today))
    }

    func testAVerifiedAnswerIsTheOneARepeatHears() {
        registerOnce()
        let identity = PendingIdentity.identify(externalId: "member-1001", email: nil, identityToken: Contract.identityToken)
        store.pendingIdentity = identity
        StubServer.enqueue(StubResponse(status: 200, body: Data(#"{"identity_verified":true}"#.utf8)))

        _ = sync.run()

        XCTAssertEqual(store.repeatedAnswer(identity, day: Int(harness.now / Self.day)), true)
    }

    func testTheAcceptedIdentityIsNoReasonToSkipWhileAnotherCallWaits() {
        registerOnce()
        let today = Int(harness.now / Self.day)
        store.acceptedIdentity = AcceptedIdentity(
            fingerprint: PushStore.identityFingerprint(installId: store.installId!, externalId: "member-1001", email: nil, hasToken: false), day: today, verified: false)
        store.pendingIdentity = .logout

        XCTAssertNil(store.repeatedAnswer(.identify(externalId: "member-1001", email: nil, identityToken: nil), day: today))
    }

    func testARefusedIdentifyAndALogoutForgetTheAcceptedIdentity() {
        registerOnce()
        let today = Int(harness.now / Self.day)
        let accepted = AcceptedIdentity(
            fingerprint: PushStore.identityFingerprint(installId: store.installId!, externalId: "member-1001", email: nil, hasToken: false), day: today, verified: false)
        store.acceptedIdentity = accepted
        store.pendingIdentity = .identify(externalId: "member-1001", email: nil, identityToken: nil)
        StubServer.enqueue(.error(400, "validation_failed"))

        _ = sync.run()

        XCTAssertNil(store.acceptedIdentity)

        store.acceptedIdentity = accepted
        store.pendingIdentity = .logout
        StubServer.enqueue(StubResponse(status: 204, body: Data()))

        _ = sync.run()

        XCTAssertNil(store.acceptedIdentity)
    }

    func testATokenOnlyIdentifyIsNeverSkipped() {
        registerOnce()
        let identity = PendingIdentity.identify(externalId: nil, email: nil, identityToken: Contract.identityToken)
        store.pendingIdentity = identity
        StubServer.enqueue(StubResponse(status: 200, body: Data(#"{"identity_verified":true}"#.utf8)))

        _ = sync.run()

        XCTAssertNil(store.repeatedAnswer(identity, day: Int(harness.now / Self.day)))
    }

    func testASuccessWithoutTheServicesAnswerIsNotRemembered() {
        registerOnce()
        store.pendingIdentity = .identify(externalId: "member-1001", email: nil, identityToken: nil)
        StubServer.enqueue(StubResponse(status: 200, body: Data("{}".utf8)))

        _ = sync.run()

        XCTAssertNil(store.acceptedIdentity)
    }

    func testANewAppKeyForgetsTheAcceptedIdentity() {
        registerOnce()
        store.acceptedIdentity = AcceptedIdentity(
            fingerprint: PushStore.identityFingerprint(installId: store.installId!, externalId: "member-1001", email: nil, hasToken: false),
            day: Int(harness.now / Self.day),
            verified: false)

        store.replaceAppKey("dtpk_prd_live_Fixture0AppKey000000000000000000")

        XCTAssertNil(store.acceptedIdentity)
    }

    func testAChangeOfRequireVerifiedIdentityForgetsTheAcceptedIdentity() {
        registerOnce()
        let accepted = AcceptedIdentity(
            fingerprint: PushStore.identityFingerprint(installId: store.installId!, externalId: "member-1001", email: nil, hasToken: false),
            day: Int(harness.now / Self.day),
            verified: false)
        store.acceptedIdentity = accepted

        let unchanged = store.requireVerifiedIdentity
        store.requireVerifiedIdentity = unchanged
        XCTAssertEqual(store.acceptedIdentity, accepted)

        store.requireVerifiedIdentity = !store.requireVerifiedIdentity
        XCTAssertNil(store.acceptedIdentity)
    }

    func testANewInstallForgetsTheAcceptedIdentity() {
        registerOnce()
        store.acceptedIdentity = AcceptedIdentity(fingerprint: "x", day: 1, verified: false)

        store.dropInstall()

        XCTAssertNil(store.acceptedIdentity)
    }

    private func registerOnce(file: StaticString = #filePath, line: UInt = #line) {
        StubServer.enqueue(.created())
        XCTAssertEqual(sync.run(), .done, file: file, line: line)
    }

    private static func config(transport: String) -> StubResponse {
        StubResponse(status: 200, body: Data(#"{"require_verified_identity":false,"platforms":{"ios":{"transport":"\#(transport)"}},"refresh_after_seconds":3600}"#.utf8))
    }

    private static func accepted(_ count: Int) -> StubResponse {
        let results = (0 ..< count).map { #"{"index":\#($0),"result":"accepted"}"# }.joined(separator: ",")
        return StubResponse(status: 202, body: Data(#"{"results":[\#(results)]}"#.utf8))
    }
}
