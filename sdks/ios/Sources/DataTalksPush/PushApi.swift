import Foundation

/// A service response. `json` is the decoded body; `code` and `detail` come from its `error` object.
struct ApiResponse {
    let status: Int
    let json: [String: Any]?
    let retryAfterSeconds: Int?

    var isSuccess: Bool { (200 ..< 300).contains(status) }

    var code: String? { error?["code"] as? String }

    var detail: String? { error?["detail"] as? String }

    private var error: [String: Any]? { json?["error"] as? [String: Any] }
}

enum PushApiError: Error {
    case badUrl
    case noResponse
}

/// A blocking call to the ingress, made on the SDK's queue. Nothing here logs: keys, secrets, tokens and identities pass through it.
struct PushApi {
    private static let requestTimeout: TimeInterval = 30

    let baseUrl: String
    let appKey: String
    let session: URLSession

    /// Throws for a network error, which the contract retries with backoff.
    func call(_ method: String, _ path: String, deviceSecret: String? = nil, body: [String: Any]? = nil) throws -> ApiResponse {
        guard let url = URL(string: baseUrl + path) else { throw PushApiError.badUrl }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.requestTimeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(appKey, forHTTPHeaderField: "X-DataTalks-App-Key")
        request.setValue(SdkInfo.header, forHTTPHeaderField: "X-DataTalks-SDK")
        if let deviceSecret {
            request.setValue(deviceSecret, forHTTPHeaderField: "X-DataTalks-Device-Secret")
        }

        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let finished = DispatchSemaphore(value: 0)
        var answer: (data: Data?, response: URLResponse?, error: Error?)
        session.dataTask(with: request) { data, response, error in
            answer = (data, response, error)
            finished.signal()
        }.resume()
        finished.wait()

        if let error = answer.error { throw error }
        guard let response = answer.response as? HTTPURLResponse else { throw PushApiError.noResponse }

        let json = answer.data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
        return ApiResponse(status: response.statusCode, json: json, retryAfterSeconds: retryAfter)
    }
}
