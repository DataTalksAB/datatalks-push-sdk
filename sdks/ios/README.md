# Data Talks Push for iOS

`DataTalksPush` for Swift Package Manager. iOS 14 or later, no third-party dependencies. Pushes go through APNs with your app's own key, or through your own Firebase project if your iOS app already uses one ([see below](#apps-that-send-through-firebase)).

## Install

Add `https://github.com/DataTalksTeam/datatalks-push-sdk` as a package in Xcode, and give the app the **Push Notifications** capability.

## Start

```swift
import DataTalksPush
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        DataTalksPush.listener = myListener
        DataTalksPush.useAsNotificationCenterDelegate()
        DataTalksPush.initialize(appKey: "dtpk_prd_live_...")
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        DataTalksPush.didRegisterForRemoteNotifications(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        DataTalksPush.didFailToRegisterForRemoteNotifications(error: error)
    }
}
```

The SDK requests the APNs token itself and registers the device once the token arrives. It doesn't swizzle, so forward these two callbacks. A SwiftUI app gets them through `@UIApplicationDelegateAdaptor`.

```swift
DataTalksPush.requestPermission { permission in }           // or provisional: true, which shows no prompt
DataTalksPush.permissionStatus { permission in }            // .authorized, .denied, .notDetermined, .provisional or .ephemeral
DataTalksPush.identify(externalId: id, identityToken: token) // after sign-in, with the token your backend signed; a same-day repeat returns the earlier result
DataTalksPush.logout()
DataTalksPush.setMarketingOptIn(false)
DataTalksPush.deleteLocalData()                             // deletes the install too; the SDK stays off until the next initialize
```

These calls return immediately; results go to `DataTalksPush.listener`. A tap that arrives before a listener is set is held for the first listener; only the latest one is kept.

```swift
final class MyListener: DataTalksPushListener {
    func onNotificationOpened(deepLink: String?, data: [String: Any]?) { /* ... */ }
    func onMessageReceived(_ message: DataTalksMessage) { /* a push while the app is open: uid, title, body, imageUrl, deepLink, data */ }
    func onIdentityResult(_ result: DataTalksIdentityResult) { /* a refused identify isn't retried */ }
}
```

## Apps that send through Firebase

If your iOS app already gets its pushes through its own Firebase project, set the iOS transport to FCM in the portal and pass the FCM
registration token to the SDK each time Firebase Messaging reports it:

```swift
import FirebaseMessaging

extension AppDelegate: MessagingDelegate {
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        if let fcmToken { DataTalksPush.setFcmToken(fcmToken) }
    }
}
```

Set `Messaging.messaging().delegate` right after `FirebaseApp.configure()`: Firebase calls it at every launch and whenever the token
changes. The SDK doesn't link Firebase; your app keeps its own setup, and Firebase still needs the APNs token (its swizzling passes it
on, or set `Messaging.messaging().apnsToken` in `didRegisterForRemoteNotificationsWithDeviceToken`). FCM delivers through APNs, so taps,
the notification delegate and the [service extension](#pictures-and-delivery-receipts) work as they do with APNs. Until a token
arrives, the SDK registers nothing and logs a warning.

## An app with its own notification delegate

`useAsNotificationCenterDelegate()` forwards notifications that aren't from Data Talks to the previously set delegate. Or keep your own delegate and forward to the SDK:

```swift
func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    if let options = DataTalksPush.handleWillPresent(notification) {
        completionHandler(options)
    } else {
        // Not from Data Talks: yours to handle.
    }
}

func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
    if !DataTalksPush.handleNotificationResponse(response) {
        // Not from Data Talks: yours to handle.
    }

    completionHandler()
}
```

Either way, set the delegate before `application(_:didFinishLaunchingWithOptions:)` returns, or a tap that launched the app is missed.

## Pictures and delivery receipts

A Notification Service Extension shows a push's picture and reports its delivery as soon as it arrives, whether or not the app is
running. Without one, iOS shows only the text, and the service counts a push as delivered once it's opened.

1. In Xcode, **File → New → Target… → Notification Service Extension**. Add the `DataTalksPushExtension` product of this package to
   it, not `DataTalksPush`: the extension needs nothing else, and an extension can't link the app's SDK.
2. Replace the generated class with this subclass and nothing else:

   ```swift
   import DataTalksPushExtension

   class NotificationService: DataTalksNotificationService {}
   ```

3. Give the app and the extension the same App Group (**Signing & Capabilities → + Capability → App Groups**, for example
   `group.com.example.app`), and name it in both Info.plists:

   ```xml
   <key>DataTalksAppGroup</key>
   <string>group.com.example.app</string>
   ```

Through the App Group, the app gives the extension what it needs to report a delivery (the key, the install id and its secret, in a
folder excluded from backups), and the extension leaves any delivery it couldn't send for the app to send. No other app data goes
there. Without the App Group, or with the name in only one Info.plist, the picture still shows. Use a group that only the app and its
extension share: two apps with this SDK in one group would take each other's deliveries.

- **Pictures**: `https` JPEG, PNG or GIF, at most 5 MB, downloaded within 10 seconds. A picture that takes longer is skipped, and the push shows without it.
- **`xcrun simctl push` doesn't run a service extension**: the simulator shows the push as sent. Test pictures and receipts with a
  push through APNs, on a device or on a simulator on an Apple silicon Mac.

## What to expect

- **A tap** opens the push's link. `https` links go through the system, so your universal links work. Other schemes open only if your app declares them in `CFBundleURLTypes`. Without a link, the tap just opens the app. An app that routes links itself passes `DataTalksPushOptions(openLinks: false)`; the link then only reaches `onNotificationOpened`.
- **Opens and clicks** are reported to the campaign's results (contract 1.1.0): an open for each tap, plus a click when the push has a link, whether the SDK or your app opens it. They are queued on the device (up to 200, for up to 30 days) and sent with the next sync while the app runs. They carry the push's id and the time, nothing about the person or the device.
- **Delivery** is reported by the app's [Notification Service Extension](#pictures-and-delivery-receipts). Without one, the service counts an opened push as delivered.
- **The APNs environment** comes from the app's provisioning profile: `sandbox` for development builds and `production` for all others, App Store builds included. A simulator is `sandbox`. Through Firebase, Firebase picks it.
- **A reinstall is a new install.** The Keychain survives an uninstall, but the SDK starts over, since uninstalling the app also signs the user out.
- **Retries run only while the app runs.** Anything left when the app stops is sent at the next launch: iOS offers an SDK no way to run it later unless the app adds a background mode.
- **Pictures** need the [Notification Service Extension](#pictures-and-delivery-receipts) too.

## The sample

`samples/swiftui` is DT Native on iOS, one of the [sample apps](../../README.md#sample-apps): key input, register, permission, identify, logout, consent, delete, and the events the SDK reports. Its bundle identifier is `se.datatalks.sandbox`, and it handles links with its own `dtpushsample://` scheme.

Its `NotificationService` target is the extension above: the one-line subclass, sharing `group.se.datatalks.sandbox` with the app.

On a simulator it runs as is. For a device, open `DataTalksPushSample.xcodeproj` and choose your team under **Signing & Capabilities** for both targets. The team needs App IDs for `se.datatalks.sandbox` (with Push Notifications) and `se.datatalks.sandbox.NotificationService`, both with the App Group `group.se.datatalks.sandbox`; otherwise change the identifiers to ones it has.

A simulator on Apple silicon gets a real APNs token; elsewhere, the `-testToken <hex>` launch argument provides one. `xcrun simctl push` delivers a push.

## Tests

From the repository's root:

```bash
xcodebuild test -scheme DataTalksPush-Package -destination "platform=iOS Simulator,name=iPhone 17"
```

The tests replay [`spec/fixtures`](../../spec/fixtures) against a stub `URLProtocol` and check request bodies against the OpenAPI document. The real-Keychain test skips itself because a package's test host has no Keychain access; running the sample covers it.

The sample's UI tests need a running ingress, and pushes delivered with `xcrun simctl push` while they wait. Without the settings below they skip themselves:

```bash
TEST_RUNNER_SAMPLE_APP_KEY=dtpk_stg_live_... TEST_RUNNER_SAMPLE_BASE_URL=http://localhost:5000/v1 TEST_RUNNER_SAMPLE_TEST_TOKEN=a1b2... xcodebuild test -project sdks/ios/samples/swiftui/DataTalksPushSample.xcodeproj -scheme DataTalksPushSample -destination "platform=iOS Simulator,name=iPhone 17"
```

A push payload for the simulator:

```json
{
  "aps": { "alert": { "title": "Match day tomorrow", "body": "Gates open at 17:00." }, "mutable-content": 1 },
  "dt_v": "1",
  "dt_uid": "push_1",
  "dt_data": "{\"ticket_id\":\"T-1042\"}"
}
```
