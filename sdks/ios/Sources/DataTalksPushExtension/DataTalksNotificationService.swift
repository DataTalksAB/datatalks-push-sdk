import Foundation
import UserNotifications

/// The notification service extension for an app that uses DataTalksPush. It attaches a Data Talks push's picture (`dt_image`) and
/// reports its delivery immediately, which only an extension can do since the app may not be running. The app's extension target is
/// this class and nothing more:
///
/// ```swift
/// import DataTalksPushExtension
///
/// class NotificationService: DataTalksNotificationService {}
/// ```
///
/// Delivery receipts also need an App Group shared by the app and the extension, named in both Info.plists as `DataTalksAppGroup`.
/// Without it the picture still shows, and the service counts a push as delivered once it's opened. Other pushes pass through unchanged.
open class DataTalksNotificationService: UNNotificationServiceExtension {
    // Guarded by `lock`: set when a push arrives, read when it's shown, which either the finished work or the time limit can trigger.
    private let lock = NSLock()
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var original: UNNotificationContent?
    // The content to show. The picture is attached as soon as it downloads, so a push shown on timeout still has it.
    private var bestAttempt: UNMutableNotificationContent?

    // Internal so that tests can replace it.
    var environment = ExtensionEnvironment.live

    override public init() {
        super.init()
    }

    override open func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let userInfo = request.content.userInfo
        let content = userInfo["dt_v"] == nil ? nil : request.content.mutableCopy() as? UNMutableNotificationContent

        lock.lock()
        self.contentHandler = contentHandler
        original = request.content
        bestAttempt = content
        lock.unlock()

        guard content != nil else {
            finish(with: request.content)
            return
        }

        let work = DispatchGroup()

        if let uid = userInfo["dt_uid"] as? String, !uid.isEmpty, let shared = environment.shared() {
            let state = shared.state()
            if let delivery = shared.recordDelivery(uid: uid, at: environment.now(), installId: state?.installId), let state {
                work.enter()
                DeliveryReporter(session: environment.session).report(delivery, state: state) { answered in
                    if answered { shared.forget(delivery) }
                    work.leave()
                }
            }
        }

        if let url = PushAttachment.url(userInfo["dt_image"] as? String) {
            work.enter()
            PushAttachment.download(url, session: environment.session) { [self] attachment in
                if let attachment { attach(attachment) }
                work.leave()
            }
        }

        work.notify(queue: .global()) { [self] in
            if let shown = contentSoFar { finish(with: shown) }
        }
    }

    /// Time is up: shows the push with whatever has arrived. An unacknowledged delivery stays in the inbox for the app to send.
    override open func serviceExtensionTimeWillExpire() {
        if let shown = contentSoFar { finish(with: shown) }
    }

    /// The content as it would show now.
    var contentSoFar: UNNotificationContent? {
        lock.lock()
        defer { lock.unlock() }
        return bestAttempt ?? original
    }

    // Only before the push is shown: after that the system owns the content.
    private func attach(_ attachment: UNNotificationAttachment) {
        lock.lock()
        defer { lock.unlock() }
        if contentHandler != nil { bestAttempt?.attachments = [attachment] }
    }

    // Calls the content handler once only.
    private func finish(with content: UNNotificationContent) {
        lock.lock()
        let handler = contentHandler
        contentHandler = nil
        lock.unlock()

        handler?(content)
    }
}

/// The extension's outside dependencies, replaceable in tests.
struct ExtensionEnvironment {
    var shared: () -> ExtensionShared?
    var session: URLSession
    var now: () -> TimeInterval

    static let live = ExtensionEnvironment(
        shared: { ExtensionShared.forExtension() },
        session: URLSession(configuration: liveConfiguration),
        now: { Date().timeIntervalSince1970 }
    )

    /// A request's own timeout only covers idle time; this caps each call's total time, well within the extension's 30 seconds.
    static var liveConfiguration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = PushAttachment.downloadTimeout
        return configuration
    }
}
