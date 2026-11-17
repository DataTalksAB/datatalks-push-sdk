import Foundation
import UserNotifications

/// The Data Talks push SDK. Call `initialize` from `application(_:didFinishLaunchingWithOptions:)`.
///
/// Calls return immediately and never throw for a service error. Work runs on the SDK's own serial queue, and work left when the
/// app stops resumes at the next launch. Results go to `listener`.
public enum DataTalksPush {
    /// Receives opens, messages and identify results. Set it before `initialize`; it is held strongly. The latest tap that arrived
    /// while no listener was set goes to the next listener set.
    public static var listener: DataTalksPushListener? {
        get { PushRuntime.shared.listener }
        set { PushRuntime.shared.listener = newValue }
    }

    /// Starts the SDK with the app's publishable key and requests an APNs token. The key selects the host.
    public static func initialize(appKey: String, options: DataTalksPushOptions = DataTalksPushOptions()) {
        guard AppKeys.baseUrl(appKey) != nil else {
            PushLog.error("The app key is malformed: the SDK stays off. Copy the key from the portal.")
            return
        }

        PushRuntime.shared.start(appKey: appKey, baseUrl: options.baseUrl, openLinks: options.openLinks)
    }

    /// Forward `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)` here.
    public static func didRegisterForRemoteNotifications(deviceToken: Data) {
        PushRuntime.shared.onNewToken(deviceToken.map { String(format: "%02x", $0) }.joined())
    }

    /// Forward `application(_:didFailToRegisterForRemoteNotificationsWithError:)` here. The install registers once a token arrives.
    public static func didFailToRegisterForRemoteNotifications(error: Error) {
        PushLog.warning("APNs gave no token: \(error.localizedDescription)")
    }

    /// Requests the notification permission (alert, sound and badge). A `provisional` request shows no prompt and delivers quietly.
    /// `completion` receives the resulting status on the main thread.
    public static func requestPermission(provisional: Bool = false, completion: ((DataTalksPermission) -> Void)? = nil) {
        PushRuntime.shared.requestPermission(provisional: provisional, completion: completion)
    }

    /// The current notification permission, passed to `completion` on the main thread.
    public static func permissionStatus(completion: @escaping (DataTalksPermission) -> Void) {
        PushRuntime.shared.permissionStatus(completion: completion)
    }

    /// Links this install to the signed-in user. Pass the `identityToken` your backend signed for this user; an app that requires
    /// verified identity refuses a call without one. The result goes to `DataTalksPushListener.onIdentityResult`. A refused identify
    /// isn't retried: call it again at the next sign-in.
    ///
    /// Repeating the same external id and email (with or without a token, as before) on the same UTC day makes no call: the listener
    /// gets the earlier result, which says nothing about the token passed this time. An identify with only a token is always sent.
    public static func identify(externalId: String? = nil, email: String? = nil, identityToken: String? = nil) {
        guard [externalId, email, identityToken].contains(where: { !($0 ?? "").isEmpty }) else {
            PushLog.warning("identify needs an external id, an email or an identity token.")
            return
        }

        PushRuntime.shared.send(identity: .identify(externalId: externalId, email: email, identityToken: identityToken))
    }

    /// Unlinks this install from its user. The install stays registered.
    public static func logout() {
        PushRuntime.shared.send(identity: .logout)
    }

    /// Records the user's in-app marketing choice on this device. Transactional pushes aren't affected.
    public static func setMarketingOptIn(_ optIn: Bool) {
        PushRuntime.shared.setMarketingOptIn(optIn)
    }

    /// Deletes this install on the service and all SDK data on the device. The SDK stays off until the next `initialize`,
    /// which creates a new install.
    public static func deleteLocalData() {
        PushRuntime.shared.deleteLocalData()
    }

    /// Makes the SDK the notification center's delegate. Other notifications go to the previous delegate. Call it before
    /// `application(_:didFinishLaunchingWithOptions:)` returns, or a tap that launched the app is missed.
    public static func useAsNotificationCenterDelegate() {
        NotificationCenterForwarder.install()
    }

    /// For an app with its own `UNUserNotificationCenterDelegate`: forward `didReceive` here. Returns true for a Data Talks
    /// push, which the SDK has handled, and false for any other notification, which the app handles.
    @discardableResult
    public static func handleNotificationResponse(_ response: UNNotificationResponse) -> Bool {
        let userInfo = response.notification.request.content.userInfo
        guard PushMessage(userInfo: userInfo) != nil else { return false }
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            PushRuntime.shared.notificationOpened(userInfo: userInfo)
        }

        return true
    }

    /// For an app with its own `UNUserNotificationCenterDelegate`: forward `willPresent` here. Returns the presentation options
    /// for a Data Talks push while the app is open, or nil for any other notification, which the app handles.
    public static func handleWillPresent(_ notification: UNNotification) -> UNNotificationPresentationOptions? {
        guard let message = PushMessage(userInfo: notification.request.content.userInfo) else { return nil }
        PushRuntime.shared.notifyMessage(message.toPublic())
        return [.banner, .list, .sound]
    }
}
