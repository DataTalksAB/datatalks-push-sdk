import Foundation
@testable import DataTalksPush

struct StubResponse {
    let status: Int
    var headers: [String: String] = [:]
    var body: Data?

    static func created() -> StubResponse {
        StubResponse(status: 201, body: Data(#"{"install_id":"\#(Contract.installId)","device_secret":"\#(Contract.deviceSecret)"}"#.utf8))
    }

    static func updated() -> StubResponse {
        StubResponse(status: 200, body: Data(#"{"install_id":"\#(Contract.installId)"}"#.utf8))
    }

    static func error(_ status: Int, _ code: String, retryAfter: String? = nil) -> StubResponse {
        StubResponse(status: status, headers: retryAfter.map { ["Retry-After": $0] } ?? [:], body: Data(#"{"error":{"code":"\#(code)","message":"x"}}"#.utf8))
    }
}

struct RecordedRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data?

    var json: [String: Any] {
        body.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
    }
}

/// Answers the SDK's requests from a queue and records them. With an empty queue it fails the request like a network error.
final class StubServer: URLProtocol {
    private static let lock = NSLock()
    private static var responses: [StubResponse] = []
    private static var recorded: [RecordedRequest] = []

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        responses = []
        recorded = []
    }

    static func enqueue(_ response: StubResponse) {
        lock.lock()
        defer { lock.unlock() }
        responses.append(response)
    }

    static var requests: [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let record = RecordedRequest(method: request.httpMethod ?? "GET", path: url.path, headers: request.allHTTPHeaderFields ?? [:], body: Self.body(of: request))

        Self.lock.lock()
        Self.recorded.append(record)
        let next = Self.responses.isEmpty ? nil : Self.responses.removeFirst()
        Self.lock.unlock()

        guard let next else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }

        let response = HTTPURLResponse(url: url, statusCode: next.status, httpVersion: "HTTP/1.1", headerFields: next.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let body = next.body { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    // A URLProtocol gets the body as a stream.
    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }

        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }

        return data
    }
}

final class MemoryValues: SecureValues {
    var stored: [String: String] = [:]
    var refuseWrites = false

    func read(_ name: String) -> String? { stored[name] }

    func write(_ name: String, _ value: String?) -> Bool {
        if refuseWrites { return false }
        stored[name] = value
        return true
    }

    func removeAll() { stored.removeAll() }
}

final class FakeFacts: DeviceFacts {
    var currentPermission = "authorized"
    var environment = "production"
    var facts = ["app_version": "4.12.0", "device_manufacturer": "Apple", "device_model": "iPhone15,2", "locale": "sv-SE"]

    func metadata() -> [String: String] { facts }

    func permission() -> String { currentPermission }
}

/// A `PushSync` on a stub server and a fresh store, with the clock and the device facts controlled by the test.
final class SyncHarness {
    let values = MemoryValues()
    let defaults: UserDefaults
    let store: PushStore
    let facts = FakeFacts()
    var identityResults: [DataTalksIdentityResult] = []
    var now: TimeInterval = 1_800_000_000
    private(set) lazy var sync = PushSync(
        store: store,
        facts: facts,
        session: Self.stubSession(),
        onIdentityResult: { [unowned self] in identityResults.append($0) },
        clock: { [unowned self] in now }
    )

    init() {
        let suite = "se.datatalks.push.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        store = PushStore(values: values, defaults: defaults)
        store.appKey = Contract.appKey
        store.baseUrl = "https://ingress.example.test/v1"
        store.configExpiresAt = .greatestFiniteMagnitude
        _ = store.updateToken(Contract.apnsToken)
        StubServer.reset()
    }

    private static func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubServer.self]
        return URLSession(configuration: configuration)
    }
}
