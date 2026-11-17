import Foundation

/// Callbacks from the SDK, on the main thread. Every method has an empty default: implement the ones you need.
public protocol DataTalksPushListener: AnyObject {
    /// The user tapped a notification. The SDK opens `deepLink`, if any, unless `DataTalksPushOptions.openLinks` is false.
    /// A tap that arrived while no listener was set, such as the one that launched the app, goes to the next listener set.
    func onNotificationOpened(deepLink: String?, data: [String: Any]?)

    /// A Data Talks push arrived while the app was in the foreground. Pushes to a closed app go only to the system.
    func onMessageReceived(_ message: DataTalksMessage)

    /// The service answered a `DataTalksPush.identify`.
    func onIdentityResult(_ result: DataTalksIdentityResult)
}

public extension DataTalksPushListener {
    func onNotificationOpened(deepLink: String?, data: [String: Any]?) {}

    func onMessageReceived(_ message: DataTalksMessage) {}

    func onIdentityResult(_ result: DataTalksIdentityResult) {}
}

/// A Data Talks push, read from its `dt_*` keys. The fields match the Android SDK's.
public struct DataTalksMessage {
    public let uid: String?
    public let title: String?
    public let body: String?
    /// The picture's `https` URL. iOS shows it only with a notification service extension (`DataTalksNotificationService`).
    public let imageUrl: String?
    public let deepLink: String?
    public let data: [String: Any]?
}

/// The result of an identify. A non-nil `errorCode` means it was refused and won't be retried; `errorDetail` says why an identity
/// token failed. It never reveals whether a profile was found.
public struct DataTalksIdentityResult {
    public let verified: Bool
    public let errorCode: String?
    public let errorDetail: String?

    init(verified: Bool, errorCode: String? = nil, errorDetail: String? = nil) {
        self.verified = verified
        self.errorCode = errorCode
        self.errorDetail = errorDetail
    }
}

/// Whether this app may show notifications. The raw value is the name the service and the other SDKs use.
public enum DataTalksPermission: String {
    case authorized
    case denied
    case notDetermined = "not_determined"
    /// Pushes arrive quietly, in the notification center only.
    case provisional
    /// An App Clip's temporary permission.
    case ephemeral
}

public struct DataTalksPushOptions {
    /// Replaces the host the key selects. Only for testing against a local ingress.
    public var baseUrl: String?

    /// Set to false for an app that routes links itself: a tap then opens nothing and only passes the link to
    /// `onNotificationOpened`.
    public var openLinks: Bool

    public init(baseUrl: String? = nil, openLinks: Bool = true) {
        self.baseUrl = baseUrl
        self.openLinks = openLinks
    }
}
