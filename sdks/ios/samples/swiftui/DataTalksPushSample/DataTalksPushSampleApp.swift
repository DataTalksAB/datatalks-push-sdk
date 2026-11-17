import DataTalksPush
import SwiftUI
import UIKit

@main
struct DataTalksPushSampleApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL(perform: SampleEvents.shared.linkOpened)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        DataTalksPush.listener = SampleEvents.shared
        DataTalksPush.useAsNotificationCenterDelegate()

        let settings = SampleSettings()
        if let key = settings.appKey {
            DataTalksPush.initialize(appKey: key, options: DataTalksPushOptions(baseUrl: settings.baseUrl))
        }

        // A simulator without a signed APNs entitlement gets no token; -testToken <hex> provides one instead.
        if let token = settings.testToken {
            DataTalksPush.didRegisterForRemoteNotifications(deviceToken: token)
        }

        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        DataTalksPush.didRegisterForRemoteNotifications(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        DataTalksPush.didFailToRegisterForRemoteNotifications(error: error)
    }
}

/// What the SDK reported, newest first, worded as in the other demos.
final class SampleEvents: ObservableObject, DataTalksPushListener {
    static let shared = SampleEvents()

    @Published private(set) var lines: [String] = []

    func add(_ line: String) {
        lines.insert(line, at: 0)
    }

    func onNotificationOpened(deepLink: String?, data: [String: Any]?) {
        let dataText = data.map { "\($0)" } ?? "none"
        add("Opened: \(deepLink ?? "the app"), data: \(dataText)")
    }

    func onMessageReceived(_ message: DataTalksMessage) {
        let text = [message.title, message.body].compactMap { $0 }.joined(separator: " ")
        add("Message \(message.uid ?? "without an id")\(text.isEmpty ? "" : ": \(text)")")
    }

    func onIdentityResult(_ result: DataTalksIdentityResult) {
        if let code = result.errorCode {
            add("Identify refused: \(code) \(result.errorDetail ?? "")")
        } else {
            add("Identify accepted, verified: \(result.verified)")
        }
    }

    func linkOpened(_ url: URL) {
        add("Link: \(url.absoluteString)")
    }
}

/// The key and host typed on the screen, kept for the next launch. A launch argument (-appKey <key>) overrides them for scripted runs.
final class SampleSettings {
    private let defaults = UserDefaults.standard

    var appKey: String? {
        get { defaults.string(forKey: "appKey") }
        set { defaults.set(newValue, forKey: "appKey") }
    }

    var baseUrl: String? {
        get { defaults.string(forKey: "baseUrl") }
        set { defaults.set(newValue, forKey: "baseUrl") }
    }

    var testToken: Data? {
        guard let hex = defaults.string(forKey: "testToken"), hex.count.isMultiple(of: 2) else { return nil }

        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index ..< next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }

        return Data(bytes)
    }
}
