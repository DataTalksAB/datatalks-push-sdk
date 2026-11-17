import UserNotifications
import XCTest
@testable import DataTalksPush
@testable import DataTalksPushExtension

/// The notification service extension (`DataTalksPushExtension`) and the app's side of the App Group (`SharedContainer`). Each side's
/// files are read here with the other side's code.
final class ExtensionTests: XCTestCase {
    private static let uid = "8b0c6f7e-2d1a-4c3b-9a5e-0f1e2d3c4b5a"
    private static let baseUrl = "https://ingress.example.test/v1"
    private static let now: TimeInterval = 1_800_000_000

    // A 1×1 PNG.
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!

    private var directory: URL!

    private var app: SharedContainer { SharedContainer(directory: directory) }

    private var shared: ExtensionShared { ExtensionShared(directory: directory) }

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("dtpush-\(UUID().uuidString)", isDirectory: true)
        StubServer.reset()
        SlowServer.reset()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testADelivery_IsReportedAtOnce_AndForgottenOnceAnswered() {
        givenTheAppsState()
        StubServer.enqueue(Self.accepted)

        let shown = receive(Self.ours())

        let request = StubServer.requests.single
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/v1/devices/\(Contract.installId)/events")
        XCTAssertEqual(request.headers["X-DataTalks-App-Key"], Contract.appKey)
        XCTAssertEqual(request.headers["X-DataTalks-Device-Secret"], Contract.deviceSecret)
        XCTAssertEqual(request.headers["X-DataTalks-SDK"], SdkInfo.header)
        Contract.assertFits("EventsRequest", request.json)
        let event = (request.json["events"] as? [[String: Any]])?.first
        XCTAssertEqual(event?["type"] as? String, "delivery")
        XCTAssertEqual(event?["uid"] as? String, Self.uid)
        XCTAssertEqual(event?["occurred_at"] as? String, Timestamps.utc(Self.now))
        XCTAssertTrue(inboxFiles().isEmpty)
        XCTAssertEqual(shown.title, "Hi")
    }

    func testAnUnansweredDelivery_WaitsForTheApp_WhichSendsTheSameEvent() {
        givenTheAppsState()

        _ = receive(Self.ours())

        XCTAssertEqual(inboxFiles().count, 1)
        XCTAssertEqual(inboxEntries().first?["install_id"] as? String, Contract.installId)
        let sentId = ((StubServer.requests.single.json["events"] as? [[String: Any]])?.first?["event_id"] as? String)
        let store = appStore()
        store.installId = Contract.installId
        store.mergeInbox()
        let pending = store.pendingEvents(now: Self.now)
        XCTAssertEqual(pending.map(\.type), ["delivery"])
        XCTAssertEqual(pending.first?.uid, Self.uid)
        XCTAssertEqual(pending.first?.eventId, sentId)
        XCTAssertEqual(pending.first?.occurredAt, Self.now)
        XCTAssertTrue(inboxFiles().isEmpty)
    }

    func testARefusedDelivery_IsLeftToTheApp_WhichKnowsWhatTheAnswerMeans() {
        givenTheAppsState()
        StubServer.enqueue(.error(503, "unavailable", retryAfter: "5"))

        _ = receive(Self.ours())

        XCTAssertEqual(inboxFiles().count, 1)
    }

    func testASuccessWithoutResults_IsNoAnswer_AndTheDeliveryWaits() {
        givenTheAppsState()
        StubServer.enqueue(StubResponse(status: 200, body: Data("{}".utf8)))

        _ = receive(Self.ours())

        XCTAssertEqual(StubServer.requests.count, 1)
        XCTAssertEqual(inboxFiles().count, 1)
    }

    func testWithoutTheAppsState_TheDeliveryWaitsForTheApp() {
        _ = receive(Self.ours())

        XCTAssertTrue(StubServer.requests.isEmpty)
        XCTAssertEqual(inboxFiles().count, 1)
    }

    func testAPushThatIsntOurs_PassesUntouched() {
        givenTheAppsState()

        let shown = receive(["aps": ["alert": ["title": "Hi"]], "dt_uid": Self.uid, "dt_image": "https://cdn.example.test/a.png"])

        XCTAssertTrue(StubServer.requests.isEmpty)
        XCTAssertTrue(inboxFiles().isEmpty)
        XCTAssertEqual(shown.title, "Hi")
        XCTAssertTrue(shown.attachments.isEmpty)
    }

    func testThePicture_IsAttached() {
        StubServer.enqueue(StubResponse(status: 200, body: Self.png))

        let shown = receive(Self.ours(image: "https://cdn.example.test/offer.png"))

        XCTAssertEqual(StubServer.requests.single.path, "/offer.png")
        XCTAssertEqual(shown.attachments.map(\.identifier), ["dt_image"])
    }

    func testAPictureThatIsntOneToShow_IsLeftOut() {
        // Not https: never downloaded.
        XCTAssertTrue(receive(Self.ours(image: "http://cdn.example.test/offer.png")).attachments.isEmpty)
        XCTAssertTrue(StubServer.requests.isEmpty)

        // Not a picture, not there, too big.
        var tooBig = Self.png
        tooBig.append(Data(count: PushAttachment.maxBytes))
        for answer in [StubResponse(status: 200, body: Data("<html>Sign in</html>".utf8)), StubResponse(status: 404), StubResponse(status: 200, body: tooBig)] {
            StubServer.enqueue(answer)
            XCTAssertTrue(receive(Self.ours(image: "https://cdn.example.test/offer.png")).attachments.isEmpty)
        }
    }

    func testAPicture_OfAtMost5MB_IsShown() {
        XCTAssertFalse(PushAttachment.accepts(size: 0))
        XCTAssertTrue(PushAttachment.accepts(size: 1))
        XCTAssertTrue(PushAttachment.accepts(size: PushAttachment.maxBytes))
        XCTAssertFalse(PushAttachment.accepts(size: PushAttachment.maxBytes + 1))
    }

    func testWhenTimeRunsOut_ThePushShowsAsItCame_Once() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NeverAnswers.self]
        let service = makeService(session: URLSession(configuration: configuration))
        var shown: [UNNotificationContent] = []

        service.didReceive(Self.request(Self.ours(image: "https://cdn.example.test/offer.png"))) { shown.append($0) }
        service.serviceExtensionTimeWillExpire()
        service.serviceExtensionTimeWillExpire()

        XCTAssertEqual(shown.count, 1)
        XCTAssertEqual(shown.first?.title, "Hi")
        XCTAssertEqual(shown.first?.attachments.isEmpty, true)
        XCTAssertEqual(inboxFiles().count, 1, "the delivery waits for the app")
    }

    func testWhenTimeRunsOut_APictureThatArrived_StaysWithThePush() {
        givenTheAppsState()
        let service = makeService(session: SlowServer.session())
        var shown: [UNNotificationContent] = []

        service.didReceive(Self.request(Self.ours(image: "https://cdn.example.test/offer.png"))) { shown.append($0) }
        let attached = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in service.contentSoFar?.attachments.isEmpty == false }, object: nil)
        wait(for: [attached], timeout: 10)
        service.serviceExtensionTimeWillExpire()

        XCTAssertEqual(shown.count, 1)
        XCTAssertEqual(shown.first?.attachments.map(\.identifier), ["dt_image"])
        XCTAssertEqual(inboxFiles().count, 1, "the delivery's call is still unanswered")
    }

    func testWorkThatEndsAfterTheTime_ChangesNothingShown() {
        givenTheAppsState()
        SlowServer.delay = 0.5
        SlowServer.answersDelivery = true
        let service = makeService(session: SlowServer.session())
        let shownAgain = expectation(description: "shown a second time")
        shownAgain.isInverted = true
        var shown: [UNNotificationContent] = []

        service.didReceive(Self.request(Self.ours(image: "https://cdn.example.test/offer.png"))) {
            shown.append($0)
            if shown.count > 1 { shownAgain.fulfill() }
        }
        service.serviceExtensionTimeWillExpire()
        XCTAssertEqual(shown.count, 1)

        // The delivery is acknowledged late but still doesn't wait for the app; the picture arrives too late to show.
        let answered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.inboxFiles().isEmpty }, object: nil)
        wait(for: [answered], timeout: 10)
        wait(for: [shownAgain], timeout: 1)
        XCTAssertEqual(SlowServer.answered, 2)
        XCTAssertEqual(shown.first?.attachments.isEmpty, true)
    }

    func testTheTwoSides_ReadEachOthersFiles() {
        givenTheAppsState()
        XCTAssertEqual(shared.state(), ExtensionState(appKey: Contract.appKey, baseUrl: Self.baseUrl, installId: Contract.installId, deviceSecret: Contract.deviceSecret))

        let delivery = shared.recordDelivery(uid: Self.uid, at: Self.now, installId: Contract.installId)
        let taken = app.takeInbox()
        let event = PushEvent(eventId: delivery!.eventId, type: PushEvent.delivery, uid: Self.uid, occurredAt: Self.now, link: nil)
        XCTAssertEqual(taken, [InboxDelivery(event: event, installId: Contract.installId)])
        XCTAssertTrue(app.takeInbox().isEmpty)

        _ = shared.recordDelivery(uid: Self.uid, at: Self.now, installId: nil)
        XCTAssertNil(app.takeInbox().single.installId, "before the app has an install")

        app.writeState(appKey: Contract.appKey, baseUrl: Self.baseUrl, installId: nil, deviceSecret: nil)
        XCTAssertNil(shared.state())
    }

    func testTheStore_GivesTheExtensionItsInstall_AndTakesItAwayWithIt() {
        let store = appStore()
        store.appKey = Contract.appKey
        XCTAssertNil(shared.state(), "nothing to report with before the install")

        store.installId = Contract.installId
        store.deviceSecret = Contract.deviceSecret
        XCTAssertEqual(shared.state()?.baseUrl, "https://push.staging.datatalks.se/v1", "the key's host when the app sets none")
        store.baseUrl = Self.baseUrl
        XCTAssertEqual(shared.state()?.baseUrl, Self.baseUrl)

        store.dropInstall()
        XCTAssertNil(shared.state())

        store.installId = Contract.installId
        store.deviceSecret = Contract.deviceSecret
        XCTAssertNotNil(shared.state())
        store.wipe()
        XCTAssertNil(shared.state())
    }

    func testADeliveryToAnotherInstall_IsNeverSent() {
        let store = appStore()
        store.installId = Contract.installId
        let ours = shared.recordDelivery(uid: Self.uid, at: Self.now - 2, installId: Contract.installId)!
        let before = shared.recordDelivery(uid: Self.uid, at: Self.now - 1, installId: nil)!
        _ = shared.recordDelivery(uid: Self.uid, at: Self.now, installId: "4f7d9c1e-0b2a-4e6f-8d3c-5a1b9e0f2c7d")

        store.mergeInbox()

        XCTAssertEqual(store.pendingEvents(now: Self.now).map(\.eventId), [ours.eventId, before.eventId])
        XCTAssertTrue(inboxFiles().isEmpty)
    }

    func testAnInstallThatGoes_TakesItsInboxWithIt() {
        let store = appStore()
        store.installId = Contract.installId
        _ = shared.recordDelivery(uid: Self.uid, at: Self.now, installId: Contract.installId)
        store.dropInstall()
        XCTAssertTrue(inboxFiles().isEmpty)

        store.installId = Contract.installId
        _ = shared.recordDelivery(uid: Self.uid, at: Self.now, installId: Contract.installId)
        store.wipe()
        XCTAssertTrue(inboxFiles().isEmpty)
    }

    func testAnUnreadableInboxFile_Goes() throws {
        let inbox = directory.appendingPathComponent("inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: inbox.appendingPathComponent("broken.json"))
        try Data(#"{"event_id":"x"}"#.utf8).write(to: inbox.appendingPathComponent("partial.json"))

        XCTAssertTrue(app.takeInbox().isEmpty)
        XCTAssertTrue(inboxFiles().isEmpty)
    }

    func testTheSharedFolder_IsNeverInABackup() throws {
        _ = shared.recordDelivery(uid: Self.uid, at: Self.now, installId: nil)
        XCTAssertTrue(try isExcludedFromBackup(directory), "the extension's first delivery")

        try FileManager.default.removeItem(at: directory)
        givenTheAppsState()
        XCTAssertTrue(try isExcludedFromBackup(directory), "the app's state")
    }

    func testTheInbox_KeepsTheNewest200_AndNothingOlderThan30Days() {
        let store = appStore()
        store.installId = Contract.installId
        _ = shared.recordDelivery(uid: Self.uid, at: Self.now - 31 * 86400, installId: Contract.installId)
        store.mergeInbox()
        XCTAssertTrue(store.pendingEvents(now: Self.now).isEmpty, "the service would no longer take it")

        // Two merges, because the extension's own inbox stops at 200.
        for age in 0 ..< 205 {
            _ = shared.recordDelivery(uid: Self.uid, at: Self.now - TimeInterval(age), installId: Contract.installId)
            if age == 104 { store.mergeInbox() }
        }
        store.mergeInbox()

        let pending = store.pendingEvents(now: Self.now)
        XCTAssertEqual(pending.count, 200)
        XCTAssertEqual(pending.first?.occurredAt, Self.now - 199)
        XCTAssertEqual(pending.last?.occurredAt, Self.now)
    }

    func testAFullInbox_KeepsNothingMore_ButTheDeliveryIsStillReported() {
        for _ in 0 ..< ExtensionShared.inboxLimit {
            _ = shared.recordDelivery(uid: Self.uid, at: Self.now, installId: Contract.installId)
        }
        XCTAssertEqual(inboxFiles().count, ExtensionShared.inboxLimit)

        XCTAssertNotNil(shared.recordDelivery(uid: Self.uid, at: Self.now, installId: Contract.installId), "the extension still sends it")
        XCTAssertEqual(inboxFiles().count, ExtensionShared.inboxLimit)

        givenTheAppsState()
        StubServer.enqueue(Self.accepted)
        let shown = receive(Self.ours())
        XCTAssertEqual(StubServer.requests.count, 1, "an app that never empties the inbox still gets its deliveries reported")
        XCTAssertEqual(shown.title, "Hi")
        XCTAssertEqual(inboxFiles().count, ExtensionShared.inboxLimit)
    }

    func testTheTwoSides_NameTheSameGroupKeyAndFiles() {
        XCTAssertEqual(ExtensionShared.appGroupInfoKey, SharedContainer.appGroupInfoKey)
        XCTAssertEqual(ExtensionShared.folderName, SharedContainer.folderName)
        XCTAssertEqual(ExtensionShared.stateFileName, SharedContainer.stateFileName)
        XCTAssertEqual(ExtensionShared.inboxFolderName, SharedContainer.inboxFolderName)
    }

    func testADeliveryInTheInbox_MakesASyncDue_AndTakesItsPlaceOldestFirst_Once() {
        let store = appStore()
        store.appKey = Contract.appKey
        store.installId = Contract.installId
        store.deviceSecret = Contract.deviceSecret
        store.markRegistered(day: Int(Self.now / 86400), permission: "authorized")
        let sync = PushSync(store: store, facts: FakeFacts(), session: URLSession(configuration: .ephemeral), onIdentityResult: { _ in }, clock: { Self.now })
        XCTAssertFalse(sync.isDue())

        store.queueEvent(PushEvent.open, uid: Self.uid, occurredAt: Self.now)
        let delivery = shared.recordDelivery(uid: Self.uid, at: Self.now - 60, installId: Contract.installId)!
        let file = directory.appendingPathComponent("inbox/\(delivery.eventId).json")
        let copy = try! Data(contentsOf: file)
        XCTAssertTrue(sync.isDue())
        XCTAssertEqual(store.pendingEvents(now: Self.now).map(\.type), ["delivery", "open"])

        // The same delivery again, as when the extension's file outlives its acknowledgement: the queue already has it.
        try! copy.write(to: file)
        store.mergeInbox()
        XCTAssertEqual(store.pendingEvents(now: Self.now).map(\.type), ["delivery", "open"])
    }

    func testTheExtension_SaysWhoItIs_AsTheAppDoes() {
        XCTAssertEqual(DeliveryReporter.sdkHeader, SdkInfo.header)
    }

    // MARK: - Support

    static let acceptedBody = Data(#"{"results":[{"index":0,"result":"accepted"}]}"#.utf8)
    private static let accepted = StubResponse(status: 202, body: acceptedBody)

    private static func ours(image: String? = nil) -> [AnyHashable: Any] {
        var userInfo: [AnyHashable: Any] = ["dt_v": "1", "dt_uid": uid, "aps": ["alert": ["title": "Hi", "body": "Your offer"], "mutable-content": 1]]
        userInfo["dt_image"] = image
        return userInfo
    }

    private static func request(_ userInfo: [AnyHashable: Any]) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "Hi"
        content.userInfo = userInfo
        return UNNotificationRequest(identifier: "push", content: content, trigger: nil)
    }

    private static func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubServer.self]
        return URLSession(configuration: configuration)
    }

    private func givenTheAppsState() {
        app.writeState(appKey: Contract.appKey, baseUrl: Self.baseUrl, installId: Contract.installId, deviceSecret: Contract.deviceSecret)
    }

    private func makeService(session: URLSession = ExtensionTests.stubSession()) -> DataTalksNotificationService {
        let service = DataTalksNotificationService()
        let container = shared
        service.environment = ExtensionEnvironment(shared: { container }, session: session, now: { Self.now })
        return service
    }

    private func receive(_ userInfo: [AnyHashable: Any]) -> UNNotificationContent {
        let shown = expectation(description: "the push is shown")
        var content: UNNotificationContent?
        makeService().didReceive(Self.request(userInfo)) {
            content = $0
            shown.fulfill()
        }

        wait(for: [shown], timeout: 15)
        return content!
    }

    private func appStore() -> PushStore {
        let suite = "se.datatalks.push.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return PushStore(values: MemoryValues(), defaults: defaults, shared: app)
    }

    private func inboxFiles() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("inbox"), includingPropertiesForKeys: nil)) ?? []
    }

    private func inboxEntries() -> [[String: Any]] {
        inboxFiles().compactMap { file in
            (try? Data(contentsOf: file)).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        }
    }

    // A new URL: a URL that has read the value before keeps it cached.
    private func isExcludedFromBackup(_ folder: URL) throws -> Bool {
        try URL(fileURLWithPath: folder.path).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
    }
}

/// Answers after `delay`, on the loading thread: the picture always, the delivery's call only when `answersDelivery`.
private final class SlowServer: URLProtocol {
    private static let lock = NSLock()
    static var delay: TimeInterval = 0
    static var answersDelivery = false
    private static var answeredCount = 0

    static var answered: Int {
        lock.lock()
        defer { lock.unlock() }
        return answeredCount
    }

    static func reset() {
        delay = 0
        answersDelivery = false
        lock.lock()
        answeredCount = 0
        lock.unlock()
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SlowServer.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let isPicture = request.httpMethod == "GET"
        guard isPicture || Self.answersDelivery else { return }

        let runLoop = CFRunLoopGetCurrent()
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.delay) { [self] in
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [self] in
                answer(isPicture ? ExtensionTests.png : ExtensionTests.acceptedBody)
            }
            CFRunLoopWakeUp(runLoop)
        }
    }

    override func stopLoading() {}

    private func answer(_ body: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
        Self.lock.lock()
        Self.answeredCount += 1
        Self.lock.unlock()
    }
}

/// A server that never answers: the extension's time runs out first.
private final class NeverAnswers: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {}

    override func stopLoading() {}
}

private extension Array {
    /// The one element; fails the test otherwise.
    var single: Element {
        XCTAssertEqual(count, 1)
        return self[0]
    }
}
