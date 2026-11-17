import Foundation
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

/// The SDK's state for one app process. All store and sync access goes through `queue`, which also keeps the app's calls in order.
final class PushRuntime {
    private static let defaultsSuite = "se.datatalks.push"

    static let shared = PushRuntime(
        store: PushStore(values: KeychainValues(), defaults: UserDefaults(suiteName: defaultsSuite) ?? .standard, shared: SharedContainer.forApp()),
        facts: SystemFacts(),
        session: URLSession(configuration: .ephemeral)
    )

    // Internal so that tests can wait on it.
    let queue = DispatchQueue(label: "se.datatalks.push")
    private let store: PushStore
    private let sync: PushSync
    private let facts: DeviceFacts
    private let openURL: (URL) -> Void

    // Accessed on `queue` only.
    private var retry: DispatchWorkItem?
    private var retryAt: Date?
    private var watchingTheApp = false

    // Guarded by `lock`: read on the main thread when a tap arrives.
    private let lock = NSLock()
    private var currentListener: DataTalksPushListener?
    private var currentOpenLinks = true

    // A tap that launched the app can arrive before a wrapper sets its listener. The latest one is held for the next listener.
    private var heldOpen: HeldOpen?

    var listener: DataTalksPushListener? {
        get { locked { currentListener } }
        set {
            let held: HeldOpen? = locked {
                currentListener = newValue
                let waiting = newValue == nil ? nil : heldOpen
                if newValue != nil { heldOpen = nil }
                return waiting
            }

            if let newValue, let held {
                DispatchQueue.main.async { newValue.onNotificationOpened(deepLink: held.deepLink, data: held.data) }
            }
        }
    }

    /// `DataTalksPushOptions.openLinks` from the last `initialize`. Not persisted: on iOS a tap always arrives after `initialize`.
    var openLinks: Bool {
        get { locked { currentOpenLinks } }
        set { locked { currentOpenLinks = newValue } }
    }

    init(store: PushStore, facts: DeviceFacts, session: URLSession, openURL: @escaping (URL) -> Void = PushRuntime.openWithTheSystem) {
        self.store = store
        self.facts = facts
        self.openURL = openURL

        // `unowned` is safe: the sync lives as long as the runtime, and the runtime as long as the app.
        var report: (DataTalksIdentityResult) -> Void = { _ in }
        sync = PushSync(store: store, facts: facts, session: session, onIdentityResult: { report($0) })
        report = { [unowned self] result in onMain { self.listener?.onIdentityResult(result) } }
    }

    static func openWithTheSystem(_ url: URL) {
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        #endif
    }

    func start(appKey: String, baseUrl: String?, openLinks: Bool) {
        self.openLinks = openLinks
        watchTheApp()
        registerWithApns()
        queue.async { [self] in
            if store.appKey != appKey || store.baseUrl != baseUrl {
                store.replaceAppKey(appKey)
                store.baseUrl = baseUrl
                sync.stopped = false
            }

            store.publishSharedState()
            syncIfDue()
        }
    }

    func onNewToken(_ token: String) {
        queue.async { [self] in
            if store.updateToken(token), store.appKey != nil { syncNow() }
        }
    }

    func send(identity: PendingIdentity) {
        queue.async { [self] in
            guard store.appKey != nil else {
                PushLog.error("A call before initialize: nothing happened.")
                return
            }

            warnIfATokenIsMissing(identity)

            // Already accepted today for this install: skip the call, so an app that identifies at every launch makes one call a day.
            // The listener gets the earlier result.
            if let verified = store.repeatedAnswer(identity, day: sync.today()) {
                onMain { self.listener?.onIdentityResult(DataTalksIdentityResult(verified: verified)) }
                return
            }

            store.pendingIdentity = identity
            syncNow()
        }
    }

    func setMarketingOptIn(_ optIn: Bool) {
        queue.async { [self] in
            guard store.appKey != nil else {
                PushLog.error("A call before initialize: nothing happened.")
                return
            }

            store.pendingOptIn = optIn
            syncNow()
        }
    }

    func deleteLocalData() {
        queue.async { [self] in
            var pending = store.pendingDelete
            if let key = store.appKey, let installId = store.installId, let secret = store.deviceSecret {
                pending = PendingDelete(appKey: key, baseUrl: store.baseUrl, installId: installId, deviceSecret: secret)
            }

            store.wipe()
            store.pendingDelete = pending
            if pending != nil { syncNow() }
        }
    }

    func requestPermission(provisional: Bool, completion: ((DataTalksPermission) -> Void)?) {
        var options: UNAuthorizationOptions = [.alert, .sound, .badge]
        if provisional { options.insert(.provisional) }

        // Read the status, not `granted`: `granted` can't tell provisional from full authorization.
        UNUserNotificationCenter.current().requestAuthorization(options: options) { [self] _, _ in
            if let completion { permissionStatus(completion: completion) }
            queue.async { [self] in syncIfDue() }
        }
    }

    func permissionStatus(completion: @escaping (DataTalksPermission) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let permission = DataTalksPermission(settings.authorizationStatus)
            onMain { completion(permission) }
        }
    }

    /// A tap on a Data Talks push: queues an open, plus a click when the push has a link, whether the SDK or the app opens it
    /// (`openLinks`). Deliveries come from the notification service extension (`DataTalksPushExtension`); without one, the service
    /// counts an open as a delivery.
    func notificationOpened(userInfo: [AnyHashable: Any]) {
        guard let message = PushMessage(userInfo: userInfo) else { return }

        if let uid = message.uid {
            let tappedAt = Date().timeIntervalSince1970
            let link = message.link.flatMap { $0.isEmpty ? nil : $0 }
            queue.async { [self] in
                store.queueEvent(PushEvent.open, uid: uid, occurredAt: tappedAt)
                if let link { store.queueEvent(PushEvent.click, uid: uid, occurredAt: tappedAt, link: link) }
                syncIfDue()
            }
        }

        // With `openLinks` false the app routes the link itself from `onNotificationOpened`.
        let target = openLinks ? PushLinks.target(link: message.link, declaredSchemes: PushLinks.declaredSchemes()) : nil
        let tapped = HeldOpen(deepLink: message.link, data: message.data)
        onMain { [self] in
            let current: DataTalksPushListener? = locked {
                if currentListener == nil { heldOpen = tapped }
                return currentListener
            }

            current?.onNotificationOpened(deepLink: tapped.deepLink, data: tapped.data)
            if let target { openURL(target) }
        }
    }

    func notifyMessage(_ message: DataTalksMessage) {
        onMain { [self] in listener?.onMessageReceived(message) }
    }

    private func warnIfATokenIsMissing(_ identity: PendingIdentity) {
        #if DEBUG
        if store.requireVerifiedIdentity, case .identify(_, _, nil) = identity {
            PushLog.warning("This app requires verified identity: identify without an identity token will be refused.")
        }
        #endif
    }

    /// Something changed: sync now and cancel any scheduled retry. A `Retry-After` still applies (`PushStore.notBefore`).
    private func syncNow() {
        retry?.cancel()
        retry = nil
        retryAt = nil
        runSync()
    }

    /// Nothing changed: a scheduled retry keeps its time.
    private func syncIfDue() {
        if let retryAt, retryAt > Date() { return }
        if sync.isDue() { syncNow() }
    }

    private func runSync() {
        let endBackgroundWork = beginBackgroundWork()
        defer { endBackgroundWork() }

        switch sync.run() {
        case .done:
            store.failedAttempts = 0
        case let .retryAfter(seconds):
            scheduleRetry(after: seconds)
        case .backoff:
            let attempt = store.failedAttempts
            store.failedAttempts = attempt + 1
            scheduleRetry(after: PushSync.backoffSeconds(attempt: attempt))
        }
    }

    // Retries run only while the app runs. Anything left stays in the store for the next launch: iOS can't run it later unless the
    // app adds a background mode.
    private func scheduleRetry(after seconds: Int) {
        let work = DispatchWorkItem { [self] in
            retry = nil
            retryAt = nil
            runSync()
        }

        retry = work
        retryAt = Date().addingTimeInterval(TimeInterval(seconds))
        queue.asyncAfter(deadline: .now() + .seconds(seconds), execute: work)
    }

    /// Syncs when the app becomes active: the permission can only change while the app is in the background, and the daily refresh
    /// waits for the app to be used.
    private func watchTheApp() {
        #if canImport(UIKit)
        queue.async { [self] in
            guard !watchingTheApp else { return }
            watchingTheApp = true
            NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [self] _ in
                queue.async { [self] in syncIfDue() }
            }
        }
        #endif
    }

    private func registerWithApns() {
        #if canImport(UIKit)
        onMain { UIApplication.shared.registerForRemoteNotifications() }
        #endif
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private struct HeldOpen {
        let deepLink: String?
        let data: [String: Any]?
    }

    /// Lets a call in progress finish when the user leaves the app.
    private func beginBackgroundWork() -> () -> Void {
        #if canImport(UIKit)
        let started = DispatchSemaphore(value: 0)
        var task = UIBackgroundTaskIdentifier.invalid
        onMain {
            task = UIApplication.shared.beginBackgroundTask(withName: "DataTalksPush") {
                UIApplication.shared.endBackgroundTask(task)
                task = .invalid
            }
            started.signal()
        }
        started.wait()

        return {
            onMain {
                if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
                task = .invalid
            }
        }
        #else
        return {}
        #endif
    }
}

private func onMain(_ work: @escaping () -> Void) {
    if Thread.isMainThread {
        work()
    } else {
        DispatchQueue.main.async(execute: work)
    }
}

/// `DataTalksPush.useAsNotificationCenterDelegate`: handles Data Talks notifications and forwards the rest to the previous delegate.
final class NotificationCenterForwarder: NSObject, UNUserNotificationCenterDelegate {
    private static var installed: NotificationCenterForwarder?

    private let previous: UNUserNotificationCenterDelegate?

    private init(previous: UNUserNotificationCenterDelegate?) {
        self.previous = previous
    }

    static func install() {
        let center = UNUserNotificationCenter.current()
        guard installed == nil else { return }
        let forwarder = NotificationCenterForwarder(previous: center.delegate)
        installed = forwarder
        center.delegate = forwarder
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if let options = DataTalksPush.handleWillPresent(notification) {
            completionHandler(options)
        } else if let handler = previous?.userNotificationCenter(_:willPresent:withCompletionHandler:) {
            handler(center, notification, completionHandler)
        } else {
            completionHandler([])
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if DataTalksPush.handleNotificationResponse(response) {
            completionHandler()
        } else if let handler = previous?.userNotificationCenter(_:didReceive:withCompletionHandler:) {
            handler(center, response, completionHandler)
        } else {
            completionHandler()
        }
    }
}
