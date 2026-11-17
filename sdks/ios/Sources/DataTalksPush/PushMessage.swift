import Foundation

/// A Data Talks push, read from its `dt_*` keys (`spec/payload/payload-v1.md`). The system displays `aps`; the app gets the rest.
struct PushMessage {
    let uid: String?
    let title: String?
    let body: String?
    let image: String?
    let link: String?
    let dataText: String?

    /// Nil unless the payload has `dt_v`, which marks a Data Talks push.
    init?(userInfo: [AnyHashable: Any]) {
        guard userInfo["dt_v"] != nil else { return nil }
        uid = userInfo["dt_uid"] as? String
        // The text is in both `aps.alert` and `dt_title`/`dt_body`. Prefer the alert: it is what the system displayed.
        let alert = (userInfo["aps"] as? [String: Any])?["alert"]
        title = (alert as? [String: Any])?["title"] as? String ?? userInfo["dt_title"] as? String
        body = (alert as? [String: Any])?["body"] as? String ?? alert as? String ?? userInfo["dt_body"] as? String
        image = userInfo["dt_image"] as? String
        link = userInfo["dt_link"] as? String
        dataText = userInfo["dt_data"] as? String
    }

    var data: [String: Any]? {
        guard let dataText else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(dataText.utf8))) as? [String: Any]
    }

    func toPublic() -> DataTalksMessage {
        DataTalksMessage(uid: uid, title: title, body: body, imageUrl: image, deepLink: link, data: data)
    }
}

/// Which links a tap opens: `https` links go through the system, which resolves the app's universal links. Other schemes must stay
/// inside the app, so only those the app declares in `CFBundleURLTypes` open. Otherwise the tap has already opened the app.
enum PushLinks {
    static func target(link: String?, declaredSchemes: Set<String>) -> URL? {
        guard let link, let url = URL(string: link), let scheme = url.scheme?.lowercased() else { return nil }
        return scheme == "https" || declaredSchemes.contains(scheme) ? url : nil
    }

    static func declaredSchemes(bundle: Bundle = .main) -> Set<String> {
        let types = bundle.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        return Set(types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }.map { $0.lowercased() })
    }
}
