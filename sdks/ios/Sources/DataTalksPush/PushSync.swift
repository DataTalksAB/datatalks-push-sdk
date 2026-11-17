import Foundation

enum SyncOutcome: Equatable {
    case done

    /// The service asked to wait (429, 503).
    case retryAfter(Int)

    /// Another 5xx or a network error: exponential backoff, at most an hour.
    case backoff
}

/// RFC 3339 timestamps in UTC, the format of the contract's `occurred_at`.
enum Timestamps {
    private static let format: ISO8601DateFormatter = {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format
    }()

    static func utc(_ secondsSinceEpoch: TimeInterval) -> String {
        format.string(from: Date(timeIntervalSince1970: secondsSinceEpoch))
    }
}

/// Brings the service up to date with the store, in order: the pending delete, the config, the registration, the identity call, the
/// consent and the push events. Each step reads what is still pending, so a second run is safe and the next run resumes a failed one.
/// The rules are the contract's (`info.description` in `spec/openapi/push-v1.yaml`). Used on the runtime's queue only.
final class PushSync {
    private enum Step: Equatable {
        case next

        /// The install changed: start over with the new one.
        case restart

        case stop(SyncOutcome)
    }

    private enum Code {
        static let appDisabled = "app_disabled"
        static let keyInvalid = "key_invalid"
        static let keyWrongEnvironment = "key_wrong_environment"
        static let installIdConflict = "install_id_conflict"
        static let deviceAuthFailed = "device_auth_failed"
    }

    private static let secondsPerDay: TimeInterval = 86400
    private static let maxRestarts = 3
    private static let defaultRetryAfterSeconds = 60
    private static let defaultConfigSeconds: TimeInterval = 3600
    private static let backoffBaseSeconds = 30
    private static let backoffMaxSeconds = 3600
    private static let maxEventsPerCall = 50
    private static let maxEventCallsPerRun = 4

    // The device routes accept 8 KB (8192 bytes). Each event is measured as encoded, so 50 opens fit. The envelope is {"events":[]}.
    private static let maxEventsBodyBytes = 8000
    private static let eventsEnvelopeBytes = 13

    private let store: PushStore
    private let facts: DeviceFacts
    private let session: URLSession
    private let onIdentityResult: (DataTalksIdentityResult) -> Void
    private let clock: () -> TimeInterval

    /// Set until the next app start when the app is disabled or the key refused: the same call would get the same answer.
    var stopped = false

    init(
        store: PushStore,
        facts: DeviceFacts,
        session: URLSession,
        onIdentityResult: @escaping (DataTalksIdentityResult) -> Void,
        clock: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) {
        self.store = store
        self.facts = facts
        self.session = session
        self.onIdentityResult = onIdentityResult
        self.clock = clock
    }

    /// The delay after `attempt` failed tries, with jitter so that devices don't all retry at once after an outage.
    static func backoffSeconds(attempt: Int, spread: Double = Double.random(in: 0 ... 1)) -> Int {
        let full = min(backoffBaseSeconds << min(max(attempt, 0), 10), backoffMaxSeconds)
        return Int(Double(full) * (0.8 + 0.2 * spread))
    }

    func isDue() -> Bool {
        if stopped { return false }
        store.mergeInbox()
        if store.pendingDelete != nil { return true }
        if store.appKey == nil { return false }
        return store.pendingIdentity != nil
            || store.pendingOptIn != nil
            || (store.installId != nil && store.deviceSecret != nil && store.hasEvents)
            || registrationIsDue(permission: facts.permission())
    }

    func run() -> SyncOutcome {
        do {
            return try runSteps()
        } catch {
            PushLog.warning("The service can't be reached: \(type(of: error))")
            return .backoff
        }
    }

    private func runSteps() throws -> SyncOutcome {
        if stopped { return .done }
        store.mergeInbox()

        let wait = store.notBefore - clock()
        if wait > 0 { return .retryAfter(Int(wait) + 1) }

        if case let .stop(outcome) = try sendPendingDelete() { return outcome }

        guard let key = store.appKey, let baseUrl = store.baseUrl ?? AppKeys.baseUrl(key) else { return .done }
        let api = PushApi(baseUrl: baseUrl, appKey: key, session: session)

        if case let .stop(outcome) = try readConfig(api) { return outcome }

        for _ in 0 ..< Self.maxRestarts {
            var step = try register(api)
            if step == .next { step = try sendIdentity(api) }
            if step == .next { step = try sendConsent(api) }
            if step == .next { step = try sendEvents(api) }
            switch step {
            case .next: return .done
            case .restart: continue
            case let .stop(outcome): return outcome
            }
        }

        return .backoff
    }

    private func sendPendingDelete() throws -> Step {
        guard let pending = store.pendingDelete else { return .next }
        guard let baseUrl = pending.baseUrl ?? AppKeys.baseUrl(pending.appKey) else { return .next }

        let api = PushApi(baseUrl: baseUrl, appKey: pending.appKey, session: session)
        let response = try api.call("DELETE", "/devices/\(pending.installId)", deviceSecret: pending.deviceSecret)
        if !response.isSuccess, let stop = stopFor(response) { return stop }
        store.pendingDelete = nil
        return .next
    }

    private func readConfig(_ api: PushApi) throws -> Step {
        if clock() < store.configExpiresAt { return .next }

        let response = try api.call("GET", "/config")
        guard response.isSuccess else {
            if let stop = stopFor(response) { return stop }
            PushLog.warning("The app's settings were refused: \(response.code ?? "no code")")
            return .next
        }

        guard let config = response.json else { return .stop(.backoff) }
        store.requireVerifiedIdentity = config["require_verified_identity"] as? Bool ?? false
        store.configExpiresAt = clock() + ((config["refresh_after_seconds"] as? TimeInterval) ?? Self.defaultConfigSeconds)

        let ios = (config["platforms"] as? [String: Any])?["ios"] as? [String: Any]
        guard ios?["transport"] as? String == "apns" else {
            // Registration through FCM needs the DataTalksPushFCM product, which this version doesn't include.
            PushLog.warning("The app isn't set up for iOS through APNs in the portal.")
            stopped = true
            return .stop(.done)
        }

        return .next
    }

    private func register(_ api: PushApi) throws -> Step {
        let permission = facts.permission()
        if !registrationIsDue(permission: permission) { return .next }

        // Nothing to register until APNs provides a token, which starts a new sync. The later steps wait too.
        guard let token = store.apnsToken else { return .stop(.done) }

        let installId = store.installId ?? UUID().uuidString.lowercased()
        store.installId = installId

        var body: [String: Any] = facts.metadata()
        body["install_id"] = installId
        body["platform"] = "ios"
        body["environment"] = facts.environment
        body["apns_token"] = token
        body["os_permission"] = permission

        let response = try api.call("POST", "/devices", deviceSecret: store.deviceSecret, body: body)
        if response.isSuccess {
            if let secret = response.json?["device_secret"] as? String, !secret.isEmpty {
                store.deviceSecret = secret
            }

            store.markRegistered(day: today(), permission: permission)
            return .next
        }

        if let stop = stopFor(response) { return stop }
        if response.code == Code.installIdConflict || response.code == Code.deviceAuthFailed {
            store.dropInstall()
            return .restart
        }

        // Never retried unchanged: a new token, a permission change or the next daily refresh sends it again.
        PushLog.warning("The registration was refused: \(response.code ?? "no code")")
        store.markRegistered(day: today(), permission: permission)
        return .next
    }

    private func sendIdentity(_ api: PushApi) throws -> Step {
        guard let pending = store.pendingIdentity, let installId = store.installId, let secret = store.deviceSecret else { return .next }

        let response: ApiResponse
        // The identity's fingerprint, for an identify; nil for a logout.
        var fingerprint: String?
        switch pending {
        case .logout:
            response = try api.call("POST", "/devices/\(installId)/logout", deviceSecret: secret)
        case let .identify(externalId, email, identityToken):
            fingerprint = PushStore.identityFingerprint(installId: installId, externalId: externalId, email: email, hasToken: identityToken != nil)
            let body = ["external_id": externalId, "email": email, "identity_token": identityToken].compactMapValues { $0 }
            response = try api.call("POST", "/devices/\(installId)/identify", deviceSecret: secret, body: body)
        }

        if !response.isSuccess, let stop = stopFor(response) { return stop }

        // A 2xx without `identity_verified` (a captive portal page, for example) doesn't prove the identity arrived.
        let verified = response.json?["identity_verified"] as? Bool

        // Record what the service now holds: the accepted identity, or none after a logout or a refusal, so the next identify is sent.
        if response.isSuccess, let fingerprint, let verified {
            store.acceptedIdentity = AcceptedIdentity(fingerprint: fingerprint, day: today(), verified: verified)
        } else {
            store.acceptedIdentity = nil
        }

        // Finished or refused: never replay an identify after a 401 (spec). App calls wait on this queue, so the pending call is still
        // the one sent; the check mirrors Android, where a new call can arrive in between.
        if store.pendingIdentity == pending { store.pendingIdentity = nil }

        if fingerprint != nil {
            onIdentityResult(
                response.isSuccess
                    ? DataTalksIdentityResult(verified: verified ?? false)
                    : DataTalksIdentityResult(verified: false, errorCode: response.code, errorDetail: response.detail)
            )
        }

        if response.code == Code.deviceAuthFailed {
            store.dropInstall()
            return .restart
        }

        return .next
    }

    private func sendConsent(_ api: PushApi) throws -> Step {
        guard let optIn = store.pendingOptIn, let installId = store.installId, let secret = store.deviceSecret else { return .next }

        let response = try api.call("PUT", "/devices/\(installId)/consent", deviceSecret: secret, body: ["marketing_opt_in": optIn])
        if !response.isSuccess, let stop = stopFor(response) { return stop }

        if response.code == Code.deviceAuthFailed {
            // Keep the choice for the new install.
            store.dropInstall()
            return .restart
        }

        store.pendingOptIn = nil
        return .next
    }

    /// Sends the queued events oldest first, at most `maxEventsPerCall` per call and within the device routes' body limit. Any result
    /// for an event (accepted, duplicate or skipped) removes it; a 429, a 5xx, a network error, a 404 or a 2xx without `results` keeps
    /// them all for the next run.
    private func sendEvents(_ api: PushApi) throws -> Step {
        guard let installId = store.installId, let secret = store.deviceSecret else { return .next }

        for _ in 0 ..< Self.maxEventCallsPerRun {
            let batch = eventBatch(store.pendingEvents(now: clock()))
            if batch.isEmpty { return .next }

            let response = try api.call("POST", "/devices/\(installId)/events", deviceSecret: secret, body: ["events": batch.map(Self.eventJson)])
            if response.isSuccess && !(response.json?["results"] is [Any]) {
                // Not a service response (a captive portal page, for example): nothing proves the events arrived.
                PushLog.warning("The events answer has no results.")
                return .stop(.backoff)
            }

            if !response.isSuccess {
                if let stop = stopFor(response) { return stop }
                if response.code == Code.deviceAuthFailed {
                    // The events belong to the old install: the service matches them to pushes sent to it.
                    store.dropInstall()
                    return .restart
                }

                if response.status == 404 {
                    // The route is missing (an unknown install gets a 401, not a 404): the ingress predates contract 1.1.0.
                    // Keep the events until it accepts them.
                    PushLog.warning("The service doesn't take events yet.")
                    return .stop(.backoff)
                }

                // Any other refusal would repeat: the contract forbids resending an unchanged request after a 4xx.
                PushLog.warning("Events were refused: \(response.code ?? String(response.status))")
            }

            store.removeEvents(Set(batch.map(\.eventId)))
        }

        // More events than one run sends: the rest go with the next run, within the install's rate limit.
        return .next
    }

    private func eventBatch(_ events: [PushEvent]) -> [PushEvent] {
        var batch: [PushEvent] = []
        var bytes = Self.eventsEnvelopeBytes
        for event in events {
            // Measured as encoded, plus the separating comma.
            let size = ((try? JSONSerialization.data(withJSONObject: Self.eventJson(event)))?.count ?? 0) + 1
            if batch.count == Self.maxEventsPerCall || (!batch.isEmpty && bytes + size > Self.maxEventsBodyBytes) { break }
            batch.append(event)
            bytes += size
        }

        return batch
    }

    private static func eventJson(_ event: PushEvent) -> [String: Any] {
        var json: [String: Any] = ["event_id": event.eventId, "type": event.type, "uid": event.uid, "occurred_at": Timestamps.utc(event.occurredAt)]
        json["link"] = event.link
        return json
    }

    private func registrationIsDue(permission: String) -> Bool {
        store.tokenChanged || store.installId == nil || store.registeredOn != today() || store.reportedPermission != permission
    }

    /// The responses that end this run; nil for those the step handles itself.
    private func stopFor(_ response: ApiResponse) -> Step? {
        if response.status == 429 || response.status == 503 {
            let seconds = response.retryAfterSeconds ?? Self.defaultRetryAfterSeconds
            store.notBefore = clock() + TimeInterval(seconds)
            return .stop(.retryAfter(seconds))
        }

        if response.status >= 500 { return .stop(.backoff) }

        if [Code.appDisabled, Code.keyInvalid, Code.keyWrongEnvironment].contains(response.code) {
            PushLog.warning("The service stopped this app: \(response.code ?? "no code")")
            stopped = true
            return .stop(.done)
        }

        return nil
    }

    /// Days since the epoch, in UTC: the unit of the daily refresh and of `AcceptedIdentity.day`.
    func today() -> Int {
        Int(clock() / Self.secondsPerDay)
    }
}
