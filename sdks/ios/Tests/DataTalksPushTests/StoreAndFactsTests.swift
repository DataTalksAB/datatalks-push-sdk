import UserNotifications
import XCTest
@testable import DataTalksPush

final class StoreAndFactsTests: XCTestCase {
    private static let now: TimeInterval = 1_800_000_000

    private func freshDefaults() -> UserDefaults {
        let suite = "se.datatalks.push.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testSecretsNeverReachTheDefaults() {
        let values = MemoryValues()
        let defaults = freshDefaults()
        let store = PushStore(values: values, defaults: defaults)

        store.appKey = Contract.appKey
        store.installId = Contract.installId
        store.deviceSecret = Contract.deviceSecret
        _ = store.updateToken(Contract.apnsToken)
        store.pendingIdentity = .identify(externalId: "member-1001", email: "anna@example.com", identityToken: Contract.identityToken)

        let plain = "\(defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("reported") || !$0.key.hasPrefix("NS") && !$0.key.hasPrefix("Apple") && !$0.key.hasPrefix("AK") })"
        for secret in [Contract.appKey, Contract.installId, Contract.deviceSecret, Contract.apnsToken, "member-1001", "anna@example.com", Contract.identityToken] {
            XCTAssertFalse(plain.contains(secret), secret)
        }

        XCTAssertEqual(values.stored["device_secret"], Contract.deviceSecret)
    }

    func testANewStoreReadsTheValuesBack() {
        let values = MemoryValues()
        let defaults = freshDefaults()
        let store = PushStore(values: values, defaults: defaults)
        store.deviceSecret = Contract.deviceSecret
        _ = store.updateToken(Contract.apnsToken)
        store.pendingIdentity = .identify(externalId: nil, email: "anna@example.com", identityToken: nil)
        store.pendingDelete = PendingDelete(appKey: Contract.appKey, baseUrl: nil, installId: Contract.installId, deviceSecret: Contract.deviceSecret)

        let again = PushStore(values: values, defaults: defaults)

        XCTAssertEqual(again.deviceSecret, Contract.deviceSecret)
        XCTAssertEqual(again.apnsToken, Contract.apnsToken)
        XCTAssertEqual(again.pendingIdentity, .identify(externalId: nil, email: "anna@example.com", identityToken: nil))
        XCTAssertEqual(again.pendingDelete?.installId, Contract.installId)
        XCTAssertNil(again.pendingDelete?.baseUrl)
    }

    func testAReinstallStartsAsANewInstall() {
        let values = MemoryValues()
        let first = PushStore(values: values, defaults: freshDefaults())
        first.installId = Contract.installId
        first.deviceSecret = Contract.deviceSecret

        // The Keychain survives the uninstall; the defaults don't.
        let afterReinstall = PushStore(values: values, defaults: freshDefaults())

        XCTAssertNil(afterReinstall.installId)
        XCTAssertNil(afterReinstall.deviceSecret)
    }

    func testAValueTheKeychainRefusesLivesOnlyInMemory() {
        let values = MemoryValues()
        let defaults = freshDefaults()
        let store = PushStore(values: values, defaults: defaults)
        values.refuseWrites = true

        store.deviceSecret = Contract.deviceSecret

        XCTAssertEqual(store.deviceSecret, Contract.deviceSecret)
        XCTAssertNil(PushStore(values: values, defaults: defaults).deviceSecret)
    }

    func testUpdateTokenSaysWhetherItChanged() {
        let store = PushStore(values: MemoryValues(), defaults: freshDefaults())

        XCTAssertTrue(store.updateToken(Contract.apnsToken))
        XCTAssertTrue(store.tokenChanged)
        store.markRegistered(day: 1, permission: "authorized")
        XCTAssertFalse(store.tokenChanged)

        XCTAssertFalse(store.updateToken(Contract.apnsToken))
        XCTAssertFalse(store.tokenChanged)
    }

    func testOnlyTheTokenForTheTransportInUseCountsAsAChange() {
        let store = PushStore(values: MemoryValues(), defaults: freshDefaults())

        XCTAssertTrue(store.updateFcmToken("fcm-1"))
        XCTAssertFalse(store.tokenChanged)
        XCTAssertNil(store.registrationToken)

        store.iosTransport = "fcm"
        XCTAssertTrue(store.tokenChanged)
        XCTAssertEqual(store.registrationToken, "fcm-1")
        store.markRegistered(day: 1, permission: "authorized")

        XCTAssertTrue(store.updateToken(Contract.apnsToken))
        XCTAssertFalse(store.tokenChanged)
        XCTAssertFalse(store.updateFcmToken("fcm-1"))
        XCTAssertTrue(store.updateFcmToken("fcm-2"))
        XCTAssertTrue(store.tokenChanged)

        store.markRegistered(day: 1, permission: "authorized")
        store.iosTransport = "fcm"
        XCTAssertFalse(store.tokenChanged)
    }

    func testTheEventQueueKeepsTheNewest200EachWithItsOwnId() {
        let store = PushStore(values: MemoryValues(), defaults: freshDefaults())

        for index in 0 ..< 205 {
            store.queueEvent(PushEvent.open, uid: "push-\(index)", occurredAt: Self.now + TimeInterval(index))
        }

        let events = store.pendingEvents(now: Self.now)
        XCTAssertEqual(events.count, 200)
        XCTAssertEqual(events.first?.uid, "push-5")
        XCTAssertEqual(events.last?.uid, "push-204")
        XCTAssertEqual(Set(events.map(\.eventId)).count, 200)
        XCTAssertNotNil(events[0].eventId.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", options: .regularExpression))
    }

    func testAnEventKeepsItsLinkAndTimeAndANewStoreReadsItBack() {
        let values = MemoryValues()
        let defaults = freshDefaults()
        PushStore(values: values, defaults: defaults).queueEvent(PushEvent.click, uid: "push-1", occurredAt: Self.now + 0.25, link: "https://example.com/tickets")

        let events = PushStore(values: values, defaults: defaults).pendingEvents(now: Self.now)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].type, "click")
        XCTAssertEqual(events[0].link, "https://example.com/tickets")
        XCTAssertEqual(events[0].occurredAt, Self.now + 0.25)
    }

    func testAnEventOlderThan30DaysIsDroppedAndAnsweredOnesAreForgotten() {
        let store = PushStore(values: MemoryValues(), defaults: freshDefaults())
        store.queueEvent(PushEvent.open, uid: "old", occurredAt: Self.now - 31 * 86400)
        store.queueEvent(PushEvent.open, uid: "answered", occurredAt: Self.now)
        store.queueEvent(PushEvent.open, uid: "waiting", occurredAt: Self.now)
        let answered = store.pendingEvents(now: Self.now).first(where: { $0.uid == "answered" })!.eventId

        store.removeEvents([answered])

        XCTAssertEqual(store.pendingEvents(now: Self.now).map(\.uid), ["waiting"])
    }

    func testOpensKeptBeforeContract110BecomeOpenEvents() {
        let defaults = freshDefaults()
        let store = PushStore(values: MemoryValues(), defaults: defaults)
        let before110: [[String: Any]] = [["uid": "push-1", "opened_at": Self.now], ["uid": "push-2", "opened_at": Self.now + 1]]
        defaults.set(before110, forKey: "open_events")
        store.queueEvent(PushEvent.open, uid: "push-3", occurredAt: Self.now + 2)

        let events = store.pendingEvents(now: Self.now)

        XCTAssertEqual(events.map(\.uid), ["push-1", "push-2", "push-3"])
        XCTAssertEqual(Set(events.map(\.type)), ["open"])
        XCTAssertEqual(events[0].occurredAt, Self.now, "the old entries were in seconds already")
        XCTAssertNil(defaults.object(forKey: "open_events"))
    }

    func testDroppingTheInstallDropsItsEvents() {
        let store = PushStore(values: MemoryValues(), defaults: freshDefaults())
        store.installId = Contract.installId
        store.queueEvent(PushEvent.open, uid: "push-1", occurredAt: Self.now)

        store.dropInstall()

        XCTAssertFalse(store.hasEvents)
    }

    func testWipeRemovesEverything() {
        let values = MemoryValues()
        let store = PushStore(values: values, defaults: freshDefaults())
        store.appKey = Contract.appKey
        store.installId = Contract.installId
        store.queueEvent(PushEvent.open, uid: "push-1", occurredAt: Self.now)
        _ = store.updateFcmToken("fcm-1")
        store.iosTransport = "fcm"

        store.wipe()

        XCTAssertNil(store.appKey)
        XCTAssertNil(store.installId)
        XCTAssertNil(store.fcmToken)
        XCTAssertEqual(store.iosTransport, "apns")
        XCTAssertFalse(store.hasEvents)
        XCTAssertTrue(values.stored.isEmpty)
    }

    func testTimesAreRfc3339InUtcWithMilliseconds() {
        XCTAssertEqual(Timestamps.utc(Self.now), "2027-01-15T08:00:00.000Z")
        XCTAssertEqual(Timestamps.utc(Self.now + 0.25), "2027-01-15T08:00:00.250Z")
    }

    func testAppKeysChooseTheHostAndAnythingElseIsNoKey() {
        let body = String(repeating: "A", count: 32)
        XCTAssertEqual(AppKeys.baseUrl("dtpk_prd_\(body)"), "https://push.datatalks.se/v1")
        XCTAssertEqual(AppKeys.baseUrl("dtpk_stg_\(body)"), "https://push.staging.datatalks.se/v1")
        XCTAssertEqual(AppKeys.baseUrl("dtpk_prd_live_\(body)"), "https://push.datatalks.se/v1")
        XCTAssertEqual(AppKeys.baseUrl("dtpk_prd_test_\(body)"), "https://push.datatalks.se/v1")
        XCTAssertEqual(AppKeys.baseUrl("dtpk_stg_live_\(body)"), "https://push.staging.datatalks.se/v1")
        XCTAssertNil(AppKeys.baseUrl("dtsk_prd_\(body)"))
        XCTAssertNil(AppKeys.baseUrl("dtpk_prd_live_short"))
        XCTAssertNil(AppKeys.baseUrl(""))
    }

    func testMetadataIsCutToTheContractsLengths() {
        XCTAssertEqual(SystemFacts.cut("abcdef", maxLength: 4), "abcd")
        XCTAssertEqual(SystemFacts.cut("abc", maxLength: 4), "abc")
        // A character outside the BMP counts as two units and is dropped whole if it doesn't fit.
        XCTAssertEqual(SystemFacts.cut("abc\u{1F600}", maxLength: 4), "abc")
        XCTAssertEqual(SystemFacts.cut("abc\u{1F600}", maxLength: 5), "abc\u{1F600}")
    }

    func testPermissionNamesAreTheContracts() {
        XCTAssertEqual(SystemFacts.name(of: .authorized), "authorized")
        XCTAssertEqual(SystemFacts.name(of: .denied), "denied")
        XCTAssertEqual(SystemFacts.name(of: .notDetermined), "not_determined")
        XCTAssertEqual(SystemFacts.name(of: .provisional), "provisional")
        XCTAssertEqual(SystemFacts.name(of: .ephemeral), "ephemeral")
    }

    func testAProfileWithDevelopmentApsIsSandbox() {
        XCTAssertEqual(ApsEnvironment.read(profile: profile(aps: "development")), ApsEnvironment.sandbox)
    }

    func testAProfileWithProductionApsIsProduction() {
        XCTAssertEqual(ApsEnvironment.read(profile: profile(aps: "production")), ApsEnvironment.production)
    }

    func testAProfileWithoutApsOrNoProfileIsProduction() {
        XCTAssertEqual(ApsEnvironment.read(profile: profile(aps: nil)), ApsEnvironment.production)
        XCTAssertEqual(ApsEnvironment.read(profile: Data("not a profile".utf8)), ApsEnvironment.production)
        XCTAssertEqual(ApsEnvironment.current(bundle: Bundle(for: Self.self)), ApsEnvironment.production)
    }

    func testAMessageIsOursWhenItCarriesTheVersionKey() {
        XCTAssertNotNil(PushMessage(userInfo: ["dt_v": "1", "aps": ["alert": "x"]]))
        XCTAssertNil(PushMessage(userInfo: ["aps": ["alert": "x"], "title": "Theirs"]))
    }

    func testAMessagesDataIsParsedAndBadDataIsIgnored() {
        let good = PushMessage(userInfo: ["dt_v": "1", "dt_uid": "push-1", "dt_link": "https://example.com/a", "dt_data": #"{"ticket_id":"T-1042"}"#])!
        XCTAssertEqual(good.toPublic().uid, "push-1")
        XCTAssertEqual(good.toPublic().deepLink, "https://example.com/a")
        XCTAssertEqual(good.data?["ticket_id"] as? String, "T-1042")

        XCTAssertNil(PushMessage(userInfo: ["dt_v": "1", "dt_data": "not json"])!.data)
    }

    func testAMessageCarriesTheTitleBodyAndPictureAsAndroidDoes() {
        let shown = PushMessage(userInfo: [
            "dt_v": "1", "aps": ["alert": ["title": "Match day", "body": "Gates open at 17:00."]],
            "dt_title": "Old title", "dt_image": "https://cdn.example.com/push/matchday.jpg",
        ])!.toPublic()
        XCTAssertEqual(shown.title, "Match day", "the alert is what the system showed")
        XCTAssertEqual(shown.body, "Gates open at 17:00.")
        XCTAssertEqual(shown.imageUrl, "https://cdn.example.com/push/matchday.jpg")

        let plainAlert = PushMessage(userInfo: ["dt_v": "1", "aps": ["alert": "Just a body"]])!.toPublic()
        XCTAssertNil(plainAlert.title)
        XCTAssertEqual(plainAlert.body, "Just a body")

        let noAlert = PushMessage(userInfo: ["dt_v": "1", "dt_title": "Title", "dt_body": "Body"])!.toPublic()
        XCTAssertEqual(noAlert.title, "Title")
        XCTAssertEqual(noAlert.body, "Body")
        XCTAssertNil(noAlert.imageUrl)
    }

    func testATapOpensHttpsAndOnlyTheAppsOwnSchemes() {
        let own: Set<String> = ["myapp"]
        XCTAssertEqual(PushLinks.target(link: "https://example.com/a", declaredSchemes: own)?.absoluteString, "https://example.com/a")
        XCTAssertEqual(PushLinks.target(link: "myapp://tickets/1", declaredSchemes: own)?.absoluteString, "myapp://tickets/1")
        XCTAssertNil(PushLinks.target(link: "otherapp://tickets/1", declaredSchemes: own))
        XCTAssertNil(PushLinks.target(link: "http://example.com/a", declaredSchemes: own))
        XCTAssertNil(PushLinks.target(link: nil, declaredSchemes: own))
    }

    func testTheKeychainKeepsAndRemovesValues() throws {
        let keychain = KeychainValues()
        guard keychain.write("test_value", "one") else {
            throw XCTSkip("This test host has no Keychain access. The sample's run on a simulator covers it.")
        }

        defer { keychain.removeAll() }
        XCTAssertEqual(keychain.read("test_value"), "one")
        XCTAssertTrue(keychain.write("test_value", "two"))
        XCTAssertEqual(keychain.read("test_value"), "two")
        XCTAssertTrue(keychain.write("test_value", nil))
        XCTAssertNil(keychain.read("test_value"))
    }

    // A profile is a plist in a signed envelope, so the bytes around the plist aren't text.
    private func profile(aps: String?) -> Data {
        var entitlements = "<key>application-identifier</key><string>TEAM.se.datatalks.push.sample</string>"
        if let aps { entitlements += "<key>aps-environment</key><string>\(aps)</string>" }
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>Name</key><string>Fixture</string><key>Entitlements</key><dict>\(entitlements)</dict></dict></plist>
        """

        return Data([0x30, 0x82, 0x1F, 0xFF, 0x00]) + Data(plist.utf8) + Data([0x00, 0xA0, 0x82, 0xFE])
    }
}
