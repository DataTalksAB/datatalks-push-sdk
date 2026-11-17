import Capacitor
import Foundation
import UserNotifications

/// Capacitor bridge to the Data Talks iOS SDK, whose sources this target compiles (`Core/`, copied in by
/// `scripts/vendor-native.mjs`). It has no logic of its own: each call forwards to `DataTalksPush`, and the SDK's listener
/// callbacks become plugin events.
@objc(DataTalksPushPlugin)
public class DataTalksPushPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "DataTalksPushPlugin"
    public let jsName = "DataTalksPush"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "checkPermissions", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "requestPermissions", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "identify", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "logout", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setMarketingOptIn", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "deleteLocalData", returnType: CAPPluginReturnPromise),
    ]

    // The router holds its handler weakly.
    private let notificationHandler = NotificationHandler()
    private let events = PluginEvents()

    override public func load() {
        // Capacitor's router owns the notification center's delegate and forwards notifications to a single push handler, so
        // this plugin replaces any other push plugin.
        if let other = bridge?.notificationRouter.pushNotificationHandler {
            Self.warn("another plugin was the push handler (\(type(of: other))) and is replaced, so it gets no notifications. Remove it, such as @capacitor/push-notifications.")
        }
        bridge?.notificationRouter.pushNotificationHandler = notificationHandler
        // Check once every plugin has loaded: a later plugin can take the handler back, and another SDK the center's delegate.
        DispatchQueue.main.async { [weak self] in self?.warnAboutOtherPushPlugins() }

        // Posted by the app delegate, with the two lines every Capacitor push plugin requires.
        NotificationCenter.default.addObserver(self, selector: #selector(didRegister(_:)), name: .capacitorDidRegisterForRemoteNotifications, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didFailToRegister(_:)), name: .capacitorDidFailToRegisterForRemoteNotifications, object: nil)

        // Listener first: a tap the SDK is holding is delivered now and retained in the plugin until the web app listens.
        events.plugin = self
        DataTalksPush.listener = events

        guard let appKey = getConfig().getString("appKey"), !appKey.isEmpty else {
            Self.warn("capacitor.config has no plugins.DataTalksPush.appKey: the SDK stays off.")
            return
        }

        let options = DataTalksPushOptions(baseUrl: getConfig().getString("baseUrl"), openLinks: getConfig().getBoolean("openLinks", true))
        DataTalksPush.initialize(appKey: appKey, options: options)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func warnAboutOtherPushPlugins() {
        guard let router = bridge?.notificationRouter else { return }

        if let handler = router.pushNotificationHandler, (handler as AnyObject) !== notificationHandler {
            Self.warn("another plugin is the push handler (\(type(of: handler))), so taps on pushes from Data Talks don't reach the SDK. Remove it, such as @capacitor/push-notifications.")
        }

        let delegate = UNUserNotificationCenter.current().delegate
        if (delegate as AnyObject?) !== router {
            let owner = delegate.map { "\(type(of: $0))" } ?? "none"
            Self.warn("the notification center's delegate isn't Capacitor's (\(owner)), so taps and pushes in the foreground don't reach the SDK. Remove the SDK that took it, and keep ios.handleApplicationNotifications on.")
        }
    }

    private static func warn(_ message: String) {
        CAPLog.print("⚡️ DataTalksPush: \(message)")
    }

    @objc private func didRegister(_ notification: Notification) {
        // A String is a Firebase token, posted when the AppDelegate asks Firebase. This SDK uses only the APNs token.
        guard let token = notification.object as? Data else { return }
        DataTalksPush.didRegisterForRemoteNotifications(deviceToken: token)
    }

    @objc private func didFailToRegister(_ notification: Notification) {
        guard let error = notification.object as? Error else { return }
        DataTalksPush.didFailToRegisterForRemoteNotifications(error: error)
    }

    @objc override public func checkPermissions(_ call: CAPPluginCall) {
        DataTalksPush.permissionStatus { call.resolve(Self.permissionResult($0)) }
    }

    @objc override public func requestPermissions(_ call: CAPPluginCall) {
        DataTalksPush.requestPermission(provisional: call.getBool("provisional") ?? false) { call.resolve(Self.permissionResult($0)) }
    }

    @objc func identify(_ call: CAPPluginCall) {
        let externalId = call.getString("externalId")
        let email = call.getString("email")
        let identityToken = call.getString("identityToken")
        guard [externalId, email, identityToken].contains(where: { !($0 ?? "").isEmpty }) else {
            call.reject("identify needs an externalId, an email or an identityToken.")
            return
        }

        DataTalksPush.identify(externalId: externalId, email: email, identityToken: identityToken)
        call.resolve()
    }

    @objc func logout(_ call: CAPPluginCall) {
        DataTalksPush.logout()
        call.resolve()
    }

    @objc func setMarketingOptIn(_ call: CAPPluginCall) {
        guard let optIn = call.getBool("optIn") else {
            call.reject("setMarketingOptIn needs optIn.")
            return
        }

        DataTalksPush.setMarketingOptIn(optIn)
        call.resolve()
    }

    @objc func deleteLocalData(_ call: CAPPluginCall) {
        DataTalksPush.deleteLocalData()
        call.resolve()
    }

    /// Capacitor's states, as `@capacitor/push-notifications` reports them: provisional and App Clip (ephemeral) count as granted.
    private static func permissionResult(_ permission: DataTalksPermission) -> [String: Any] {
        let state: String
        switch permission {
        case .authorized, .provisional, .ephemeral:
            state = "granted"
        case .denied:
            state = "denied"
        case .notDetermined:
            state = "prompt"
        }

        return ["receive": state]
    }
}

/// Receives notifications from Capacitor's router. A push from another sender gets no banner while the app is open, and its
/// tap goes nowhere: this plugin replaces any other push plugin.
private final class NotificationHandler: NSObject, NotificationHandlerProtocol {
    func willPresent(notification: UNNotification) -> UNNotificationPresentationOptions {
        DataTalksPush.handleWillPresent(notification) ?? []
    }

    func didReceive(response: UNNotificationResponse) {
        DataTalksPush.handleNotificationResponse(response)
    }
}

/// Turns the SDK's listener callbacks into plugin events. A separate object because the SDK holds its listener strongly.
private final class PluginEvents: DataTalksPushListener {
    weak var plugin: CAPPlugin?

    func onNotificationOpened(deepLink: String?, data: [String: Any]?) {
        var event: [String: Any] = [:]
        if let deepLink { event["deepLink"] = deepLink }
        if let data { event["data"] = data }
        // Retained until the web app listens: a tap that launches the app arrives before its JavaScript runs.
        plugin?.notifyListeners("notificationOpened", data: event, retainUntilConsumed: true)
    }

    func onMessageReceived(_ message: DataTalksMessage) {
        var event: [String: Any] = [:]
        if let uid = message.uid { event["uid"] = uid }
        if let title = message.title { event["title"] = title }
        if let body = message.body { event["body"] = body }
        if let imageUrl = message.imageUrl { event["imageUrl"] = imageUrl }
        if let deepLink = message.deepLink { event["deepLink"] = deepLink }
        if let data = message.data { event["data"] = data }
        plugin?.notifyListeners("messageReceived", data: event)
    }

    func onIdentityResult(_ result: DataTalksIdentityResult) {
        var event: [String: Any] = ["verified": result.verified]
        if let errorCode = result.errorCode { event["errorCode"] = errorCode }
        if let errorDetail = result.errorDetail { event["errorDetail"] = errorDetail }
        plugin?.notifyListeners("identityResult", data: event)
    }
}
