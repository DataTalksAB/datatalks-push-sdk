import Foundation

/// The App Group folder the app shares with its notification service extension (`DataTalksPushExtension`), when its Info.plist names
/// one (`DataTalksAppGroup`). The app writes what the extension needs to report a delivery (`state.json`); the extension leaves each
/// delivery in `inbox/` until its own call succeeds, and the app sends the rest. The app's own store stays out of it, and the folder is
/// excluded from backups: another device is another install.
///
/// The extension reads and writes the same files with its own code (`ExtensionShared`). Change both together, along with the tests
/// that read each side's files with the other side's code.
final class SharedContainer {
    static let appGroupInfoKey = "DataTalksAppGroup"
    static let folderName = "DataTalksPush"
    static let stateFileName = "state.json"
    static let inboxFolderName = "inbox"

    private let directory: URL
    private let fileManager: FileManager

    init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    /// The app's group container, or nil when the app names no group or isn't entitled to the one it names.
    static func forApp(bundle: Bundle = .main) -> SharedContainer? {
        guard let group = bundle.object(forInfoDictionaryKey: appGroupInfoKey) as? String, !group.isEmpty else { return nil }
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            PushLog.warning("The App Group \(group) isn't one of the app's: the extension can't report deliveries.")
            return nil
        }

        return SharedContainer(directory: root.appendingPathComponent(folderName, isDirectory: true))
    }

    private var stateFile: URL { directory.appendingPathComponent(Self.stateFileName) }

    private var inbox: URL { directory.appendingPathComponent(Self.inboxFolderName, isDirectory: true) }

    /// Writes what the extension needs to send a delivery. If a value is missing or the write fails (also when the folder can't be
    /// excluded from backups), the file is removed and deliveries wait for the app. Readable after the first unlock following a restart,
    /// like the Keychain items.
    func writeState(appKey: String?, baseUrl: String?, installId: String?, deviceSecret: String?) {
        guard let appKey, let baseUrl, let installId, let deviceSecret else {
            try? fileManager.removeItem(at: stateFile)
            return
        }

        let state = ["app_key": appKey, "base_url": baseUrl, "install_id": installId, "device_secret": deviceSecret]
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try excludeFromBackup()
            let data = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
            try data.write(to: stateFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            try? fileManager.removeItem(at: stateFile)
            PushLog.warning("The state for the notification service extension can't be written: \(type(of: error))")
        }
    }

    /// Returns and removes the deliveries the extension left; the app's queue owns them from here on. Unreadable files are removed too.
    func takeInbox() -> [InboxDelivery] {
        guard let files = try? fileManager.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil) else { return [] }

        var deliveries: [InboxDelivery] = []
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file), let delivery = Self.parse(data) {
                deliveries.append(delivery)
            }

            try? fileManager.removeItem(at: file)
        }

        return deliveries
    }

    /// The install is gone: drop what the extension left for it.
    func clearInbox() {
        try? fileManager.removeItem(at: inbox)
    }

    // The folder rather than each file, so the extension's inbox is covered too.
    private func excludeFromBackup() throws {
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
    }

    private static func parse(_ data: Data) -> InboxDelivery? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = json["event_id"] as? String, let type = json["type"] as? String, let uid = json["uid"] as? String,
              let occurredAt = json["occurred_at"] as? TimeInterval
        else { return nil }

        let event = PushEvent(eventId: id, type: type, uid: uid, occurredAt: occurredAt, link: json["link"] as? String)
        return InboxDelivery(event: event, installId: json["install_id"] as? String)
    }
}

/// A delivery the extension left, with the install id the push went to if the app had one at the time.
struct InboxDelivery: Equatable {
    let event: PushEvent
    let installId: String?
}
