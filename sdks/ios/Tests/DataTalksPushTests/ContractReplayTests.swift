import XCTest
@testable import DataTalksPush

/// Replays the contract fixtures: the SDK must send what each step lists and handle each response as the contract says. Steps the SDK
/// can't produce (a missing key, an install it never held) are left to the service's own replay.
final class ContractReplayTests: XCTestCase {
    private static let replayed: Set<String> = [
        "config",
        "app-disabled",
        "key-invalid",
        "key-wrong-environment",
        "register-ios-sandbox",
        "register-platform-not-set-up",
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
    ]

    private static let notForTheIosSdk: Set<String> = [
        // Android only, or a body this SDK can't build.
        "register-android-new",
        "register-android-token",
        "register-token-transport-mismatch",
        "register-validation-failed",
        // Server-side decisions about events the SDK sends normally.
        "events-implied-unknown-skipped",
        // Calls from the customer's backend.
        "server-device-taken-over-by-sdk",
        "server-devices-delete",
        "server-devices-upsert",
    ]

    private var harness: SyncHarness!
    private var store: PushStore { harness.store }
    private var sync: PushSync { harness.sync }

    override func setUp() {
        harness = SyncHarness()
    }

    func testEveryFixtureIsReplayedOrNotForIos() throws {
        XCTAssertEqual(try Contract.fixtureNames(), Self.replayed.union(Self.notForTheIosSdk))
    }

    func testConfigIsReadWithTheAppKey() throws {
        let fixture = try Contract.fixture("config")
        store.configExpiresAt = 0
        StubServer.enqueue(fixture.response(0))
        store.installId = Contract.installId
        store.markRegistered(day: Int(harness.now / 86400), permission: "authorized")

        XCTAssertEqual(sync.run(), .done)

        fixture.assertSent(0, StubServer.requests[0])
        XCTAssertTrue(store.requireVerifiedIdentity)
    }

    func testAppDisabledStopsCallingUntilTheNextAppStart() throws {
        let fixture = try Contract.fixture("app-disabled")
        store.configExpiresAt = 0
        StubServer.enqueue(fixture.response(0))

        XCTAssertEqual(sync.run(), .done)
        fixture.assertSent(0, StubServer.requests[0])

        XCTAssertFalse(sync.isDue())
        _ = sync.run()
        XCTAssertEqual(StubServer.requests.count, 1)
    }

    func testKeyInvalidStopsCalling() throws {
        let fixture = try Contract.fixture("key-invalid")
        store.configExpiresAt = 0
        StubServer.enqueue(fixture.response(1))

        XCTAssertEqual(sync.run(), .done)
        fixture.assertSent(1, StubServer.requests[0])
        XCTAssertTrue(sync.stopped)
    }

    func testKeyWrongEnvironmentStopsCalling() throws {
        let fixture = try Contract.fixture("key-wrong-environment")
        store.configExpiresAt = 0
        StubServer.enqueue(fixture.response(0))

        XCTAssertEqual(sync.run(), .done)
        fixture.assertSent(0, StubServer.requests[0])
        XCTAssertTrue(sync.stopped)
    }

    func testRegisterIosSandboxSendsTheTokenAndEnvironmentAndKeepsTheSecret() throws {
        let fixture = try Contract.fixture("register-ios-sandbox")
        let body = fixture.requestBody(0)
        store.installId = body["install_id"] as? String
        _ = store.updateToken(body["apns_token"] as! String)
        harness.facts.environment = body["environment"] as! String
        StubServer.enqueue(fixture.response(0))

        XCTAssertEqual(sync.run(), .done)

        fixture.assertSent(0, StubServer.requests[0], schema: "RegisterDeviceRequest")
        XCTAssertEqual(StubServer.requests[0].json["platform"] as? String, "ios")
        XCTAssertEqual(store.deviceSecret, Contract.deviceSecret)
    }

    func testAnAppNotSetUpForThePlatformIsNotRetriedTheSameDay() throws {
        let fixture = try Contract.fixture("register-platform-not-set-up")
        store.installId = fixture.requestBody(0)["install_id"] as? String
        _ = store.updateToken(fixture.requestBody(0)["apns_token"] as! String)
        StubServer.enqueue(fixture.response(0))

        XCTAssertEqual(sync.run(), .done)

        fixture.assertSent(0, StubServer.requests[0], schema: "RegisterDeviceRequest")
        XCTAssertFalse(sync.isDue())
    }

    func testARefreshSendsTheNewTokenWithTheSecret() throws {
        let fixture = try Contract.fixture("register-android-refresh")
        registerFirst(fixture)

        _ = store.updateToken(String(repeating: "b", count: 64))
        StubServer.enqueue(fixture.response(1))
        XCTAssertEqual(sync.run(), .done)

        fixture.assertSent(1, StubServer.requests[1], schema: "RegisterDeviceRequest")
        XCTAssertEqual(store.deviceSecret, Contract.deviceSecret)
    }

    func testAConflictRegistersAgainUnderANewInstallId() throws {
        let fixture = try Contract.fixture("register-known-install-without-secret")
        registerFirst(fixture)

        store.deviceSecret = nil
        store.tokenChanged = true
        StubServer.enqueue(fixture.response(1))
        StubServer.enqueue(.created())
        XCTAssertEqual(sync.run(), .done)
        fixture.assertSent(1, StubServer.requests[1], schema: "RegisterDeviceRequest")
        XCTAssertNil(StubServer.requests[2].headers["X-DataTalks-Device-Secret"])
        XCTAssertNotEqual(store.installId, Contract.installId)
        XCTAssertEqual(store.deviceSecret, Contract.deviceSecret)

        store.installId = Contract.installId
        store.deviceSecret = Contract.wrongSecret
        store.tokenChanged = true
        StubServer.enqueue(fixture.response(2))
        StubServer.enqueue(.created())
        _ = sync.run()
        fixture.assertSent(2, StubServer.requests[3], schema: "RegisterDeviceRequest")
        XCTAssertNotEqual(store.installId, Contract.installId)
    }

    func testDeviceAuthFailedDropsTheInstallAndRegistersAsANewOne() throws {
        let fixture = try Contract.fixture("device-auth-failed")
        registerFirst(fixture)
        store.deviceSecret = Contract.wrongSecret
        store.pendingIdentity = .logout
        StubServer.enqueue(fixture.response(1))
        StubServer.enqueue(.created())

        XCTAssertEqual(sync.run(), .done)

        fixture.assertSent(1, StubServer.requests[1])
        XCTAssertEqual(StubServer.requests[2].path, "/v1/devices")
        XCTAssertNil(StubServer.requests[2].headers["X-DataTalks-Device-Secret"])
        XCTAssertNotEqual(store.installId, Contract.installId)
        XCTAssertNil(store.pendingIdentity)
    }

    func testIdentifyVerifiedSendsTheBodyAndReportsVerified() throws {
        let fixture = try Contract.fixture("identify-verified")
        registerFirst(fixture)
        let body = fixture.requestBody(1)
        store.pendingIdentity = .identify(externalId: body["external_id"] as? String, email: body["email"] as? String, identityToken: Contract.identityToken)
        StubServer.enqueue(fixture.response(1))

        XCTAssertEqual(sync.run(), .done)

        fixture.assertSent(1, StubServer.requests[1], schema: "IdentifyRequest")
        XCTAssertNil(store.pendingIdentity)
        XCTAssertEqual(harness.identityResults.count, 1)
        XCTAssertTrue(harness.identityResults[0].verified)
        XCTAssertNil(harness.identityResults[0].errorCode)
    }

    func testIdentifyUnverifiedIsAcceptedAsUnverified() throws {
        let fixture = try Contract.fixture("identify-unverified")
        registerFirst(fixture)
        store.pendingIdentity = .identify(externalId: nil, email: fixture.requestBody(1)["email"] as? String, identityToken: nil)
        StubServer.enqueue(fixture.response(1))

        _ = sync.run()

        fixture.assertSent(1, StubServer.requests[1], schema: "IdentifyRequest")
        XCTAssertFalse(harness.identityResults[0].verified)
        XCTAssertNil(harness.identityResults[0].errorCode)
    }

    func testIdentifyTokenRequiredIsNotReplayed() throws {
        try assertRefused("identify-token-required", code: "identity_token_required", detail: nil) { body in
            .identify(externalId: body["external_id"] as? String, email: nil, identityToken: nil)
        }
    }

    func testIdentifyTokenExpiredIsNotReplayed() throws {
        try assertRefused("identify-token-expired", code: "identity_token_invalid", detail: "expired") { _ in
            .identify(externalId: nil, email: nil, identityToken: Contract.identityToken)
        }
    }

    func testIdentifyClaimsMismatchIsNotReplayed() throws {
        try assertRefused("identify-claims-mismatch", code: "identity_token_invalid", detail: "claims_mismatch") { body in
            .identify(externalId: body["external_id"] as? String, email: nil, identityToken: Contract.identityToken)
        }
    }

    func testConsentLogoutAndDeleteAreEachSentOnce() throws {
        let fixture = try Contract.fixture("consent-logout-delete")
        registerFirst(fixture)

        store.pendingOptIn = fixture.requestBody(1)["marketing_opt_in"] as? Bool
        StubServer.enqueue(fixture.response(1))
        _ = sync.run()
        fixture.assertSent(1, StubServer.requests[1], schema: "ConsentRequest")
        XCTAssertNil(store.pendingOptIn)

        store.pendingIdentity = .logout
        StubServer.enqueue(fixture.response(2))
        _ = sync.run()
        fixture.assertSent(2, StubServer.requests[2])
        XCTAssertNil(store.pendingIdentity)

        let baseUrl = store.baseUrl
        store.wipe()
        store.pendingDelete = PendingDelete(appKey: Contract.appKey, baseUrl: baseUrl, installId: Contract.installId, deviceSecret: Contract.deviceSecret)
        StubServer.enqueue(fixture.response(3))
        XCTAssertEqual(sync.run(), .done)
        fixture.assertSent(3, StubServer.requests[3])
        XCTAssertNil(store.pendingDelete)
    }

    func testRateLimitedWaitsForRetryAfterAndSendsNothingUntilThen() throws {
        let fixture = try Contract.fixture("rate-limited")
        registerFirst(fixture)

        _ = store.updateToken(String(repeating: "c", count: 64))
        StubServer.enqueue(fixture.response(2))
        XCTAssertEqual(sync.run(), .retryAfter(1))
        XCTAssertTrue(store.tokenChanged)
        XCTAssertEqual(StubServer.requests.count, 2)

        guard case .retryAfter = sync.run() else { return XCTFail("It should still wait.") }
        XCTAssertEqual(StubServer.requests.count, 2)
    }

    func testEventsReportedGoWithTheSecretAndAreForgottenAlsoWhenTheSameCallComesBackAsDuplicates() throws {
        let fixture = try Contract.fixture("events-reported")
        registerFirst(fixture)

        queueEvents(of: fixture.requestBody(1))
        StubServer.enqueue(fixture.response(1))
        XCTAssertEqual(sync.run(), .done)
        fixture.assertSent(1, StubServer.requests[1], schema: "EventsRequest")
        XCTAssertFalse(store.hasEvents)

        // The response was lost, so the same events are sent again: `duplicate` acknowledges them just the same.
        queueEvents(of: fixture.requestBody(2))
        StubServer.enqueue(fixture.response(2))
        XCTAssertEqual(sync.run(), .done)
        fixture.assertSent(2, StubServer.requests[2], schema: "EventsRequest")
        XCTAssertFalse(store.hasEvents)
    }

    /// Queues the fixture's events as the SDK would: the same types and links, for the harness's push.
    private func queueEvents(of body: [String: Any]) {
        for event in body["events"] as! [[String: Any]] {
            store.queueEvent(event["type"] as! String, uid: "8b0c6f7e-2d1a-4c3b-9a5e-0f1e2d3c4b5a", occurredAt: harness.now, link: event["link"] as? String)
        }
    }

    private func assertRefused(_ name: String, code: String, detail: String?, identity: ([String: Any]) -> PendingIdentity, file: StaticString = #filePath, line: UInt = #line) throws {
        let fixture = try Contract.fixture(name)
        registerFirst(fixture)
        store.pendingIdentity = identity(fixture.requestBody(1))
        StubServer.enqueue(fixture.response(1))

        XCTAssertEqual(sync.run(), .done, file: file, line: line)

        fixture.assertSent(1, StubServer.requests[1], schema: "IdentifyRequest", file: file, line: line)
        XCTAssertNil(store.pendingIdentity, file: file, line: line)
        XCTAssertEqual(harness.identityResults.first?.errorCode, code, file: file, line: line)
        XCTAssertEqual(harness.identityResults.first?.errorDetail, detail, file: file, line: line)
        XCTAssertEqual(store.installId, Contract.installId, file: file, line: line)

        _ = sync.run()
        XCTAssertEqual(StubServer.requests.count, 2, file: file, line: line)
    }

    private func registerFirst(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) {
        store.installId = Contract.installId
        StubServer.enqueue(fixture.response(0))
        XCTAssertEqual(sync.run(), .done, file: file, line: line)
        fixture.assertSent(0, StubServer.requests[0], schema: "RegisterDeviceRequest", file: file, line: line)
    }
}
