import Capacitor
import UIKit

/// An app built with the iOS 27 SDK must use scenes, or iOS terminates it after the launch screen. Info.plist's
/// `UIApplicationSceneManifest` names this class.
///
/// The window comes from `Main.storyboard`, so a storyboard that names a `CAPBridgeViewController` subclass keeps working.
/// With scenes, iOS delivers links to the scene instead of the `AppDelegate`, so this class forwards them to Capacitor's
/// `ApplicationDelegateProxy` (Capacitor 8.5 and later have `SceneDelegateProxy` for this). Push needs nothing here: the
/// APNs token still reaches the `AppDelegate`, and Capacitor remains the notification center's delegate.
class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
        // The storyboard that Info.plist's UIMainStoryboardFile named. Change it if yours has another name.
        window.rootViewController = UIStoryboard(name: "Main", bundle: nil).instantiateInitialViewController()
        self.window = window
        // Loads the bridge and its plugins, so they listen before the launch link is forwarded.
        window.makeKeyAndVisible()

        open(connectionOptions.urlContexts)
        for userActivity in connectionOptions.userActivities {
            self.scene(scene, continue: userActivity)
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        open(URLContexts)
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        _ = ApplicationDelegateProxy.shared.application(UIApplication.shared, continue: userActivity) { _ in }
    }

    private func open(_ urlContexts: Set<UIOpenURLContext>) {
        for context in urlContexts {
            var options: [UIApplication.OpenURLOptionsKey: Any] = [.openInPlace: context.options.openInPlace]
            if let sourceApplication = context.options.sourceApplication {
                options[.sourceApplication] = sourceApplication
            }
            if let annotation = context.options.annotation {
                options[.annotation] = annotation
            }
            if #available(iOS 14.5, *), let eventAttribution = context.options.eventAttribution {
                options[.eventAttribution] = eventAttribution
            }

            _ = ApplicationDelegateProxy.shared.application(UIApplication.shared, open: context.url, options: options)
        }
    }
}
