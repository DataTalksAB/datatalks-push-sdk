import Foundation

/// The extension's only call: `POST /devices/{install_id}/events` with the delivery (contract 1.1.0), as the app sends its events. Only a
/// response with `results` completes the delivery; anything else (a refusal, a busy service, no network, a timeout) leaves it in the
/// inbox for the app, which handles each response. Nothing here logs: the key and the secret pass through it.
struct DeliveryReporter {
    /// Idle timeout per request; the session caps each call at 10 seconds in total, well within the extension's 30.
    static let requestTimeout: TimeInterval = 5

    /// Same value as the app's `SdkInfo.header`: the service doesn't need to tell them apart.
    static let sdkHeader = "datatalks-push-ios/1.0.0-rc.1"

    private static let timestamps: ISO8601DateFormatter = {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format
    }()

    let session: URLSession

    /// Calls `completion` on a background queue, with true if the service acknowledged the delivery.
    func report(_ event: DeliveryEvent, state: ExtensionState, completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "\(state.baseUrl)/devices/\(state.installId)/events") else {
            completion(false)
            return
        }

        let delivery: [String: Any] = [
            "event_id": event.eventId,
            "type": DeliveryEvent.type,
            "uid": event.uid,
            "occurred_at": Self.timestamps.string(from: Date(timeIntervalSince1970: event.occurredAt)),
        ]

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(state.appKey, forHTTPHeaderField: "X-DataTalks-App-Key")
        request.setValue(state.deviceSecret, forHTTPHeaderField: "X-DataTalks-Device-Secret")
        request.setValue(Self.sdkHeader, forHTTPHeaderField: "X-DataTalks-SDK")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["events": [delivery]])

        session.dataTask(with: request) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            completion((200 ..< 300).contains(status) && json?["results"] is [Any])
        }.resume()
    }
}
