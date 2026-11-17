import Foundation

/// The extension's side of the App Group it shares with the app (`DataTalksAppGroup` in both Info.plists): it reads the app's
/// `state.json` and writes `inbox/`, one file per delivery, which the app sends when the extension's own call fails. The app's side is
/// `SharedContainer` in DataTalksPush: change both together, along with the tests that read each side's files with the other's code.
struct ExtensionShared {
    static let appGroupInfoKey = "DataTalksAppGroup"
    static let folderName = "DataTalksPush"
    static let stateFileName = "state.json"
    static let inboxFolderName = "inbox"
    /// Matches the app's queue limit. An app that names no group never empties the inbox, so beyond this limit a delivery is
    /// reported but not kept.
    static let inboxLimit = 200

    let directory: URL
    var fileManager: FileManager = .default

    /// The extension's group container, or nil when its Info.plist names no group or it isn't entitled to the one it names.
    static func forExtension(bundle: Bundle = .main) -> ExtensionShared? {
        guard let group = bundle.object(forInfoDictionaryKey: appGroupInfoKey) as? String, !group.isEmpty,
              let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { return nil }

        return ExtensionShared(directory: root.appendingPathComponent(folderName, isDirectory: true))
    }

    private var inbox: URL { directory.appendingPathComponent(Self.inboxFolderName, isDirectory: true) }

    /// What the extension needs to send a delivery, as the app last wrote it; nil before the app has an install.
    func state() -> ExtensionState? {
        let file = directory.appendingPathComponent(Self.stateFileName)
        guard let data = try? Data(contentsOf: file),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: String],
              let appKey = json["app_key"], let baseUrl = json["base_url"], let installId = json["install_id"],
              let deviceSecret = json["device_secret"]
        else { return nil }

        return ExtensionState(appKey: appKey, baseUrl: baseUrl, installId: installId, deviceSecret: deviceSecret)
    }

    /// Saves a delivery for the app first, since the extension can be stopped at any time. It records the app's current install id, if
    /// any, so the app never sends it for another install. Returns nil if it can't be written; with the inbox full, returns the event
    /// without saving it.
    func recordDelivery(uid: String, at occurredAt: TimeInterval, installId: String?) -> DeliveryEvent? {
        let event = DeliveryEvent(eventId: UUID().uuidString.lowercased(), uid: uid, occurredAt: occurredAt)
        if inboxCount() >= Self.inboxLimit { return event }

        var entry: [String: Any] = ["event_id": event.eventId, "type": DeliveryEvent.type, "uid": uid, "occurred_at": occurredAt]
        entry["install_id"] = installId

        do {
            try fileManager.createDirectory(at: inbox, withIntermediateDirectories: true)
            excludeFromBackup()
            let data = try JSONSerialization.data(withJSONObject: entry)
            try data.write(to: file(of: event), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return event
        } catch {
            return nil
        }
    }

    /// The service acknowledged the delivery: the app doesn't need to send it.
    func forget(_ event: DeliveryEvent) {
        try? fileManager.removeItem(at: file(of: event))
    }

    // Another device is another install, so nothing here goes into a backup. The app does the same when it writes its state.
    private func excludeFromBackup() {
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
    }

    private func inboxCount() -> Int {
        let files = (try? fileManager.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.count
    }

    private func file(of event: DeliveryEvent) -> URL {
        inbox.appendingPathComponent("\(event.eventId).json")
    }
}

/// The app's key, host, install and secret, as `state.json` has them.
struct ExtensionState: Equatable {
    let appKey: String
    let baseUrl: String
    let installId: String
    let deviceSecret: String
}

/// A delivery the extension reports (contract 1.1.0 `PushEvent`). Created once, so the extension's call and a later one from the app send
/// the same event.
struct DeliveryEvent: Equatable {
    static let type = "delivery"

    let eventId: String
    let uid: String
    let occurredAt: TimeInterval
}
