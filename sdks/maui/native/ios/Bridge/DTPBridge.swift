import Foundation
import UserNotifications

/// The SDK's callbacks, in types Objective-C can carry. `dataJson` is the push's `dt_data` as JSON.
@objc(DTPBridgeListener)
public protocol DTPBridgeListener: NSObjectProtocol {
    @objc(notificationOpenedWithDeepLink:dataJson:)
    func notificationOpened(deepLink: String?, dataJson: String?)

    @objc(messageReceivedWithUid:title:body:imageUrl:deepLink:dataJson:)
    func messageReceived(uid: String?, title: String?, body: String?, imageUrl: String?, deepLink: String?, dataJson: String?)

    @objc(identityResultWithVerified:errorCode:errorDetail:)
    func identityResult(verified: Bool, errorCode: String?, errorDetail: String?)
}

/// The Swift SDK exposed to Objective-C, which is what a .NET binding can read. It has no logic of its own: the SDK's sources are
/// compiled into this framework, so there is one implementation per platform.
@objc(DTPBridge)
public final class DTPBridge: NSObject {
    private final class ListenerAdapter: DataTalksPushListener {
        let target: DTPBridgeListener

        init(target: DTPBridgeListener) {
            self.target = target
        }

        func onNotificationOpened(deepLink: String?, data: [String: Any]?) {
            target.notificationOpened(deepLink: deepLink, dataJson: DTPBridge.json(data))
        }

        func onMessageReceived(_ message: DataTalksMessage) {
            target.messageReceived(
                uid: message.uid, title: message.title, body: message.body, imageUrl: message.imageUrl,
                deepLink: message.deepLink, dataJson: DTPBridge.json(message.data))
        }

        func onIdentityResult(_ result: DataTalksIdentityResult) {
            target.identityResult(verified: result.verified, errorCode: result.errorCode, errorDetail: result.errorDetail)
        }
    }

    @objc(setListener:)
    public static func setListener(_ listener: DTPBridgeListener?) {
        DataTalksPush.listener = listener.map(ListenerAdapter.init(target:))
    }

    @objc(initializeWithAppKey:baseUrl:openLinks:)
    public static func initialize(appKey: String, baseUrl: String?, openLinks: Bool) {
        DataTalksPush.initialize(appKey: appKey, options: DataTalksPushOptions(baseUrl: baseUrl, openLinks: openLinks))
    }

    @objc(didRegisterForRemoteNotificationsWithDeviceToken:)
    public static func didRegisterForRemoteNotifications(deviceToken: Data) {
        DataTalksPush.didRegisterForRemoteNotifications(deviceToken: deviceToken)
    }

    @objc(didFailToRegisterForRemoteNotificationsWithError:)
    public static func didFailToRegisterForRemoteNotifications(error: NSError) {
        DataTalksPush.didFailToRegisterForRemoteNotifications(error: error)
    }

    /// The answer comes on the main thread as the permission's name: authorized, denied, not_determined, provisional or ephemeral.
    @objc(requestPermissionWithProvisional:completion:)
    public static func requestPermission(provisional: Bool, completion: @escaping (String) -> Void) {
        DataTalksPush.requestPermission(provisional: provisional) { completion($0.rawValue) }
    }

    @objc(permissionStatusWithCompletion:)
    public static func permissionStatus(completion: @escaping (String) -> Void) {
        DataTalksPush.permissionStatus { completion($0.rawValue) }
    }

    @objc(identifyWithExternalId:email:identityToken:)
    public static func identify(externalId: String?, email: String?, identityToken: String?) {
        DataTalksPush.identify(externalId: externalId, email: email, identityToken: identityToken)
    }

    @objc(logout)
    public static func logout() {
        DataTalksPush.logout()
    }

    @objc(setMarketingOptIn:)
    public static func setMarketingOptIn(_ optIn: Bool) {
        DataTalksPush.setMarketingOptIn(optIn)
    }

    @objc(deleteLocalData)
    public static func deleteLocalData() {
        DataTalksPush.deleteLocalData()
    }

    @objc(useAsNotificationCenterDelegate)
    public static func useAsNotificationCenterDelegate() {
        DataTalksPush.useAsNotificationCenterDelegate()
    }

    @objc(handleNotificationResponse:)
    public static func handleNotificationResponse(_ response: UNNotificationResponse) -> Bool {
        DataTalksPush.handleNotificationResponse(response)
    }

    /// The raw value of the presentation options for a Data Talks push, or nil for any other notification.
    @objc(presentationOptionsForNotification:)
    public static func presentationOptions(for notification: UNNotification) -> NSNumber? {
        DataTalksPush.handleWillPresent(notification).map { NSNumber(value: $0.rawValue) }
    }

    private static func json(_ data: [String: Any]?) -> String? {
        guard let data, let encoded = try? JSONSerialization.data(withJSONObject: data) else { return nil }
        return String(data: encoded, encoding: .utf8)
    }
}
