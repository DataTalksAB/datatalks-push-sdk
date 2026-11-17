import UserNotifications
import XCTest
@testable import DataTalksPush

/// What the wrappers (Capacitor, MAUI) need from the SDK: links left to the app, and a tap kept for a late listener.
final class WrapperHooksTests: XCTestCase {
    private final class RecordingListener: DataTalksPushListener {
        private(set) var opened: [String?] = []
        private(set) var verified: [Bool] = []
        var expectation: XCTestExpectation?

        func onNotificationOpened(deepLink: String?, data: [String: Any]?) {
            opened.append(deepLink)
            expectation?.fulfill()
        }

        func onIdentityResult(_ result: DataTalksIdentityResult) {
            verified.append(result.verified)
            expectation?.fulfill()
        }
    }

    private var openedUrls: [URL] = []
    private var harness: SyncHarness!

    private func runtime() -> PushRuntime {
        harness = SyncHarness()
        // Without a key no sync is due. A sync would deadlock here: it waits on the main thread to begin background work, while the
        // tests block the main thread waiting for the runtime's queue. It would also need a host app and the network.
        harness.store.appKey = nil
        return PushRuntime(store: harness.store, facts: harness.facts, session: URLSession(configuration: .ephemeral)) { [unowned self] url in
            self.openedUrls.append(url)
        }
    }

    private func tap(_ runtime: PushRuntime, uid: String, link: String?) {
        var userInfo: [AnyHashable: Any] = ["dt_v": "1", "dt_uid": uid]
        userInfo["dt_link"] = link
        runtime.notificationOpened(userInfo: userInfo)
    }

    /// Runs what the SDK queued on the main thread.
    private func drainMain() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
    }

    func testARepeatedIdentifyAnswersTheListenerWithoutACall() {
        let runtime = runtime()
        // Nothing below is sent, so the key starts no sync.
        harness.store.appKey = Contract.appKey
        harness.store.installId = Contract.installId
        harness.store.acceptedIdentity = AcceptedIdentity(
            fingerprint: PushStore.identityFingerprint(installId: Contract.installId, externalId: "member-1001", email: nil, hasToken: false),
            day: Int(Date().timeIntervalSince1970 / 86_400),
            verified: true)
        let listener = RecordingListener()
        let answered = expectation(description: "identify answered")
        listener.expectation = answered
        runtime.listener = listener

        runtime.send(identity: .identify(externalId: "member-1001", email: nil, identityToken: nil))
        wait(for: [answered], timeout: 2)

        XCTAssertEqual(listener.verified, [true])
        XCTAssertNil(harness.store.pendingIdentity)
    }

    func testAnHttpsLinkIsOpenedByDefault() {
        let runtime = runtime()

        tap(runtime, uid: "push-1", link: "https://example.com/tickets")
        drainMain()

        XCTAssertEqual(openedUrls.map(\.absoluteString), ["https://example.com/tickets"])
    }

    func testWithOpenLinksOffATapOpensNothingAndHandsTheLinkToTheApp() {
        let runtime = runtime()
        runtime.openLinks = false
        let listener = RecordingListener()
        runtime.listener = listener

        tap(runtime, uid: "push-1", link: "https://example.com/tickets")
        drainMain()

        XCTAssertTrue(openedUrls.isEmpty)
        XCTAssertEqual(listener.opened, ["https://example.com/tickets"])
    }

    func testATapBeforeAnyListenerReachesTheFirstListenerSetOnlyTheNewestAndOnlyOnce() {
        let runtime = runtime()
        tap(runtime, uid: "push-1", link: "myapp://tickets/1")
        tap(runtime, uid: "push-2", link: "myapp://tickets/2")
        drainMain()

        let first = RecordingListener()
        first.expectation = expectation(description: "the held tap")
        runtime.listener = first
        XCTAssertTrue(first.opened.isEmpty, "the held tap comes after the setter returns")
        wait(for: [first.expectation!], timeout: 1)

        let second = RecordingListener()
        runtime.listener = second
        drainMain()

        XCTAssertEqual(first.opened, ["myapp://tickets/2"])
        XCTAssertTrue(second.opened.isEmpty)
    }

    func testATapWithAListenerIsNotHeldForTheNext() {
        let runtime = runtime()
        let first = RecordingListener()
        runtime.listener = first

        tap(runtime, uid: "push-1", link: nil)
        drainMain()
        let second = RecordingListener()
        runtime.listener = second
        drainMain()

        XCTAssertEqual(first.opened, [nil])
        XCTAssertTrue(second.opened.isEmpty)
    }

    func testATapKeepsAnOpenAndAClickWhenThePushHasALinkWhoeverOpensIt() {
        let runtime = runtime()
        runtime.openLinks = false

        tap(runtime, uid: "push-1", link: "https://example.com/tickets")
        tap(runtime, uid: "push-2", link: nil)
        tap(runtime, uid: "push-3", link: "")
        runtime.queue.sync {}
        drainMain()

        let events = harness.store.pendingEvents(now: Date().timeIntervalSince1970)
        XCTAssertEqual(events.map(\.type), ["open", "click", "open", "open"])
        XCTAssertEqual(events.map(\.uid), ["push-1", "push-1", "push-2", "push-3"])
        XCTAssertEqual(events[1].link, "https://example.com/tickets")
        XCTAssertEqual(events[0].occurredAt, events[1].occurredAt, "the same tap")
        XCTAssertNil(events[0].link)
    }

    func testATapOnAPushWithoutAnIdKeepsNoEvent() {
        let runtime = runtime()

        runtime.notificationOpened(userInfo: ["dt_v": "1"])
        runtime.queue.sync {}
        drainMain()

        XCTAssertFalse(harness.store.hasEvents)
    }

    func testPermissionsCarryTheContractsNames() {
        let statuses: [UNAuthorizationStatus] = [.authorized, .denied, .notDetermined, .provisional, .ephemeral]
        let expected: [DataTalksPermission] = [.authorized, .denied, .notDetermined, .provisional, .ephemeral]

        XCTAssertEqual(statuses.map { DataTalksPermission($0) }, expected)
    }
}
