import CryptoKit
import Foundation
import Security

protocol SecureValues {
    func read(_ name: String) -> String?

    /// False when the value couldn't be stored.
    func write(_ name: String, _ value: String?) -> Bool

    func removeAll()
}

/// Device-only Keychain items: a backup restored to another device doesn't include them, so that device registers as a new install.
final class KeychainValues: SecureValues {
    private let service = "se.datatalks.push"

    func read(_ name: String) -> String? {
        var query = item(name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ name: String, _ value: String?) -> Bool {
        SecItemDelete(item(name) as CFDictionary)
        guard let value else { return true }

        var attributes = item(name)
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    func removeAll() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }

    private func item(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: name]
    }
}

/// The identity call waiting to be sent. A later identify or logout replaces it.
enum PendingIdentity: Equatable {
    case logout
    case identify(externalId: String?, email: String?, identityToken: String?)
}

/// The last identity the service accepted for this install: a fingerprint (no id or email in the clear), the day (in days since the
/// epoch) and whether it was verified. A repeat identify on the same day is skipped and gets this result.
struct AcceptedIdentity: Equatable {
    let fingerprint: String
    let day: Int
    let verified: Bool
}

/// What deleting an install needs after the store is wiped.
struct PendingDelete: Equatable {
    let appKey: String
    let baseUrl: String?
    let installId: String
    let deviceSecret: String
}

/// A push event waiting for `POST /devices/{install_id}/events` (contract 1.1.0). `eventId` is generated once, so a retry after a lost
/// response sends the same events. `occurredAt` is in seconds since the epoch.
struct PushEvent: Equatable {
    static let delivery = "delivery"
    static let open = "open"
    static let click = "click"

    let eventId: String
    let type: String
    let uid: String
    let occurredAt: TimeInterval
    let link: String?
}

enum Transport {
    static let apns = "apns"
    static let fcm = "fcm"
}

/// What the SDK keeps on the device: the key, install id, secret, token and identity values in the Keychain, the rest in user
/// defaults. Used on the runtime's queue only.
final class PushStore {
    private enum Key {
        static let appKey = "app_key"
        static let installId = "install_id"
        static let deviceSecret = "device_secret"
        static let apnsToken = "apns_token"
        static let fcmToken = "fcm_token"
        static let pendingIdentity = "pending_identity"
        static let acceptedIdentity = "accepted_identity"
        static let pendingDelete = "pending_delete"

        static let installed = "installed"
        static let baseUrl = "base_url"
        static let iosTransport = "ios_transport"
        static let tokenChanged = "token_changed"
        static let registeredOn = "registered_on"
        static let reportedPermission = "reported_permission"
        static let pendingOptIn = "pending_opt_in"
        static let notBefore = "not_before"
        static let failedAttempts = "failed_attempts"
        static let configExpiresAt = "config_expires_at"
        static let requireVerifiedIdentity = "require_verified_identity"
        static let events = "events"

        // Legacy format from before contract 1.1.0: opens only, as {uid, opened_at} in seconds.
        static let legacyOpenEvents = "open_events"
    }

    private static let maxEvents = 200
    private static let maxEventAge: TimeInterval = 30 * 86400

    private let values: SecureValues
    private let defaults: UserDefaults
    private let shared: SharedContainer?

    // Values already read. Also the only copy of a value the Keychain refused, in which case the next launch registers a new install.
    private var cache: [String: String] = [:]

    init(values: SecureValues, defaults: UserDefaults, shared: SharedContainer? = nil) {
        self.values = values
        self.defaults = defaults
        self.shared = shared

        // The Keychain survives an uninstall and the defaults don't, so a reinstall clears the Keychain and starts a new install, as on
        // Android. Otherwise the reinstalled app would keep receiving the previous user's pushes.
        if !defaults.bool(forKey: Key.installed) {
            values.removeAll()
            defaults.set(true, forKey: Key.installed)
        }
    }

    var appKey: String? {
        get { readSecure(Key.appKey) }
        set {
            writeSecure(Key.appKey, newValue)
            publishSharedState()
        }
    }

    var installId: String? {
        get { readSecure(Key.installId) }
        set {
            writeSecure(Key.installId, newValue)
            publishSharedState()
        }
    }

    var deviceSecret: String? {
        get { readSecure(Key.deviceSecret) }
        set {
            writeSecure(Key.deviceSecret, newValue)
            publishSharedState()
        }
    }

    var apnsToken: String? {
        readSecure(Key.apnsToken)
    }

    /// The registration token the app passed from Firebase Messaging, for apps that send through their own Firebase project.
    var fcmToken: String? {
        readSecure(Key.fcmToken)
    }

    /// The transport the portal sets for iOS: `apns`, or `fcm` for apps that send through their own Firebase project. `apns` until
    /// the settings are read. A change registers again with the other token.
    var iosTransport: String {
        get { defaults.string(forKey: Key.iosTransport) ?? Transport.apns }
        set {
            if newValue != iosTransport { tokenChanged = true }
            defaults.set(newValue, forKey: Key.iosTransport)
        }
    }

    /// The token for the transport in use.
    var registrationToken: String? {
        iosTransport == Transport.fcm ? fcmToken : apnsToken
    }

    var baseUrl: String? {
        get { defaults.string(forKey: Key.baseUrl) }
        set {
            defaults.set(newValue, forKey: Key.baseUrl)
            publishSharedState()
        }
    }

    var tokenChanged: Bool {
        get { defaults.bool(forKey: Key.tokenChanged) }
        set { defaults.set(newValue, forKey: Key.tokenChanged) }
    }

    /// The day of the last answer to a registration, in days since the epoch.
    var registeredOn: Int? {
        defaults.object(forKey: Key.registeredOn) as? Int
    }

    var reportedPermission: String? {
        defaults.string(forKey: Key.reportedPermission)
    }

    var pendingIdentity: PendingIdentity? {
        get { readSecure(Key.pendingIdentity).flatMap(Self.parseIdentity) }
        set { writeSecure(Key.pendingIdentity, newValue.map(Self.format)) }
    }

    /// See `AcceptedIdentity`. Cleared by a logout, a refused identify, a new install or a new app key.
    var acceptedIdentity: AcceptedIdentity? {
        get { readSecure(Key.acceptedIdentity).flatMap(Self.parseAccepted) }
        set { writeSecure(Key.acceptedIdentity, newValue.map { "\($0.day)|\($0.verified ? 1 : 0)|\($0.fingerprint)" }) }
    }

    /// Today's answer for `identity` on this install when nothing else is queued, so the identify can be skipped; nil when it must be
    /// sent. Token-only identifies are never skipped: different users' tokens look the same here.
    func repeatedAnswer(_ identity: PendingIdentity, day: Int) -> Bool? {
        guard case let .identify(externalId, email, identityToken) = identity, pendingIdentity == nil,
              !(externalId ?? "").isEmpty || !(email ?? "").isEmpty,
              let installId, let accepted = acceptedIdentity, accepted.day == day,
              accepted.fingerprint == Self.identityFingerprint(installId: installId, externalId: externalId, email: email, hasToken: identityToken != nil)
        else { return nil }
        return accepted.verified
    }

    /// A SHA-256 fingerprint of the identity for one install: the ids, and whether a signed token came with them.
    static func identityFingerprint(installId: String, externalId: String?, email: String?, hasToken: Bool) -> String {
        let text = [installId, externalId ?? "", email ?? "", hasToken ? "1" : "0"].joined(separator: "\u{0}")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var pendingOptIn: Bool? {
        get { defaults.object(forKey: Key.pendingOptIn) as? Bool }
        set { defaults.set(newValue, forKey: Key.pendingOptIn) }
    }

    var pendingDelete: PendingDelete? {
        get { readSecure(Key.pendingDelete).flatMap(Self.parseDelete) }
        set { writeSecure(Key.pendingDelete, newValue.map(Self.format)) }
    }

    /// No call before this time (seconds since the epoch), set from the service's `Retry-After`.
    var notBefore: TimeInterval {
        get { defaults.double(forKey: Key.notBefore) }
        set { defaults.set(newValue, forKey: Key.notBefore) }
    }

    var failedAttempts: Int {
        get { defaults.integer(forKey: Key.failedAttempts) }
        set { defaults.set(newValue, forKey: Key.failedAttempts) }
    }

    var configExpiresAt: TimeInterval {
        get { defaults.double(forKey: Key.configExpiresAt) }
        set { defaults.set(newValue, forKey: Key.configExpiresAt) }
    }

    /// A change clears the accepted identity: an identify accepted before may now be refused.
    var requireVerifiedIdentity: Bool {
        get { defaults.bool(forKey: Key.requireVerifiedIdentity) }
        set {
            if newValue != requireVerifiedIdentity { acceptedIdentity = nil }
            defaults.set(newValue, forKey: Key.requireVerifiedIdentity)
        }
    }

    var hasEvents: Bool {
        !readEvents().isEmpty
    }

    /// Stores the APNs `token` if it differs from the stored one, and returns whether it did.
    func updateToken(_ token: String) -> Bool {
        guard apnsToken != token else { return false }
        writeSecure(Key.apnsToken, token)
        if iosTransport == Transport.apns { tokenChanged = true }
        return true
    }

    /// Stores the FCM `token` if it differs from the stored one, and returns whether it did.
    func updateFcmToken(_ token: String) -> Bool {
        guard fcmToken != token else { return false }
        writeSecure(Key.fcmToken, token)
        if iosTransport == Transport.fcm { tokenChanged = true }
        return true
    }

    /// The service accepted this registration or refused it for good: nothing to resend today.
    func markRegistered(day: Int, permission: String) {
        defaults.set(day, forKey: Key.registeredOn)
        defaults.set(permission, forKey: Key.reportedPermission)
        tokenChanged = false
    }

    /// The install is unknown or its secret is lost: the next registration creates a new install. Its events are dropped too, since the
    /// service matches each to a push sent to the old install.
    func dropInstall() {
        installId = nil
        deviceSecret = nil
        acceptedIdentity = nil
        for key in [Key.registeredOn, Key.events, Key.legacyOpenEvents] {
            defaults.removeObject(forKey: key)
        }

        shared?.clearInbox()
    }

    func replaceAppKey(_ key: String) {
        appKey = key
        // Another key can mean another environment, which doesn't know the identity.
        acceptedIdentity = nil
        configExpiresAt = 0
    }

    /// Queues an event until the service acknowledges it. Only the newest `maxEvents` are kept.
    func queueEvent(_ type: String, uid: String, occurredAt: TimeInterval, link: String? = nil) {
        var events = readEvents()
        events.append(PushEvent(eventId: UUID().uuidString.lowercased(), type: type, uid: uid, occurredAt: occurredAt, link: link))
        writeEvents(Array(events.suffix(Self.maxEvents)))
    }

    /// The events still to send, oldest first. Events older than 30 days are dropped: the service no longer accepts them.
    func pendingEvents(now: TimeInterval) -> [PushEvent] {
        let events = readEvents()
        let fresh = events.filter { now - $0.occurredAt <= Self.maxEventAge }
        if fresh.count != events.count { writeEvents(fresh) }
        return fresh
    }

    /// Moves the deliveries the notification service extension left (`SharedContainer`) into the queue, oldest first, skipping events
    /// already queued. Deliveries for another install are dropped: the service would match them to a push this install never got.
    func mergeInbox() {
        guard let shared else { return }
        let current = installId
        let arrived = shared.takeInbox().filter { $0.installId == nil || $0.installId == current }.map(\.event)
        guard !arrived.isEmpty else { return }

        var events = readEvents()
        let known = Set(events.map(\.eventId))
        events.append(contentsOf: arrived.filter { !known.contains($0.eventId) })
        writeEvents(Array(events.sorted { $0.occurredAt < $1.occurredAt }.suffix(Self.maxEvents)))
    }

    /// Writes what the notification service extension needs to report deliveries, or removes it once the install is gone. Called on
    /// every change of key, host, install or secret, and at each start in case the app just added its App Group.
    func publishSharedState() {
        guard let shared else { return }
        let key = appKey
        shared.writeState(appKey: key, baseUrl: baseUrl ?? key.flatMap(AppKeys.baseUrl), installId: installId, deviceSecret: deviceSecret)
    }

    /// Removes the events the service acknowledged.
    func removeEvents(_ eventIds: Set<String>) {
        let events = readEvents()
        let left = events.filter { !eventIds.contains($0.eventId) }
        if left.count != events.count { writeEvents(left) }
    }

    func wipe() {
        cache.removeAll()
        values.removeAll()
        for key in [
            Key.baseUrl, Key.iosTransport, Key.tokenChanged, Key.registeredOn, Key.reportedPermission, Key.pendingOptIn, Key.notBefore,
            Key.failedAttempts, Key.configExpiresAt, Key.requireVerifiedIdentity, Key.events, Key.legacyOpenEvents,
        ] {
            defaults.removeObject(forKey: key)
        }

        shared?.clearInbox()
        publishSharedState()
    }

    // Opens stored in the legacy format become open events on the first read. Every write removes them, so while they exist they
    // are the oldest entries.
    private func readEvents() -> [PushEvent] {
        let events = (defaults.array(forKey: Key.events) as? [[String: Any]] ?? []).compactMap(Self.parseEvent)
        guard let legacy = defaults.array(forKey: Key.legacyOpenEvents) as? [[String: Any]] else { return events }

        let opens = legacy.compactMap { entry -> PushEvent? in
            guard let uid = entry["uid"] as? String, let openedAt = entry["opened_at"] as? TimeInterval else { return nil }
            return PushEvent(eventId: UUID().uuidString.lowercased(), type: PushEvent.open, uid: uid, occurredAt: openedAt, link: nil)
        }

        let migrated = Array((opens + events).suffix(Self.maxEvents))
        writeEvents(migrated)
        return migrated
    }

    private func writeEvents(_ events: [PushEvent]) {
        let stored = events.map { event -> [String: Any] in
            var entry: [String: Any] = ["event_id": event.eventId, "type": event.type, "uid": event.uid, "occurred_at": event.occurredAt]
            entry["link"] = event.link
            return entry
        }

        defaults.set(stored, forKey: Key.events)
        defaults.removeObject(forKey: Key.legacyOpenEvents)
    }

    private static func parseEvent(_ entry: [String: Any]) -> PushEvent? {
        guard let id = entry["event_id"] as? String, let type = entry["type"] as? String, let uid = entry["uid"] as? String,
              let occurredAt = entry["occurred_at"] as? TimeInterval
        else { return nil }
        return PushEvent(eventId: id, type: type, uid: uid, occurredAt: occurredAt, link: entry["link"] as? String)
    }

    private func readSecure(_ name: String) -> String? {
        if let cached = cache[name] { return cached }
        let value = values.read(name)
        cache[name] = value
        return value
    }

    private func writeSecure(_ name: String, _ value: String?) {
        cache[name] = value
        if !values.write(name, value) {
            PushLog.warning("A value can't be stored in the Keychain, so it stays in memory.")
        }
    }

    private static func parseAccepted(_ text: String) -> AcceptedIdentity? {
        let parts = text.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let day = Int(parts[0]) else { return nil }
        return AcceptedIdentity(fingerprint: String(parts[2]), day: day, verified: parts[1] == "1")
    }

    private static func format(_ identity: PendingIdentity) -> String {
        switch identity {
        case .logout:
            return encode(["op": "logout"])
        case let .identify(externalId, email, identityToken):
            return encode(["op": "identify", "external_id": externalId, "email": email, "identity_token": identityToken].compactMapValues { $0 })
        }
    }

    private static func parseIdentity(_ text: String) -> PendingIdentity? {
        guard let json = decode(text) else { return nil }
        if json["op"] == "logout" { return .logout }
        return .identify(externalId: json["external_id"], email: json["email"], identityToken: json["identity_token"])
    }

    private static func format(_ delete: PendingDelete) -> String {
        encode(["app_key": delete.appKey, "base_url": delete.baseUrl, "install_id": delete.installId, "device_secret": delete.deviceSecret].compactMapValues { $0 })
    }

    private static func parseDelete(_ text: String) -> PendingDelete? {
        guard let json = decode(text), let key = json["app_key"], let install = json["install_id"], let secret = json["device_secret"] else { return nil }
        return PendingDelete(appKey: key, baseUrl: json["base_url"], installId: install, deviceSecret: secret)
    }

    private static func encode(_ values: [String: String]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: values)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func decode(_ text: String) -> [String: String]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: String]
    }
}
