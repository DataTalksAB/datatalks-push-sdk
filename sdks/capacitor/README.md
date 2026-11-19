# Data Talks Push for Capacitor

`@datatalks-ab/push-capacitor` wraps the [Android](../android/README.md) and [iOS](../ios/README.md) SDKs, with the same behaviour and rules, for JavaScript. It requires Capacitor 6 to 8, Android 6 (API 23) or later, and iOS 14 or later.

The plugin replaces any other push plugin in your app, such as `@capacitor/push-notifications` or OneSignal: see [Another push plugin](#another-push-plugin). For an Ionic React app, [guide-ionic-react.md](guide-ionic-react.md) covers the whole integration, including the identity token from your backend.

## Install

```bash
npm install @datatalks-ab/push-capacitor
npx cap sync
```

Set the app key in `capacitor.config.ts`, so the SDK starts at launch, before your web app has loaded:

```ts
plugins: {
  DataTalksPush: {
    appKey: 'dtpk_prd_...',
    openLinks: false, // the app routes a push's link itself, from notificationOpened
  },
},
```

### Android

Two changes, both under `android/`:

1. In `variables.gradle`, set `minSdkVersion = 23`. Capacitor 6's template sets 22, which fails the build with a manifest merger error.
2. In `build.gradle`, add the repository inside this package that holds the Android SDK it was built with:

```groovy
allprojects {
    repositories {
        google()
        mavenCentral()
        maven { url "${project(':datatalks-ab-push-capacitor').projectDir}/maven" }
    }
}
```

Firebase is set up as usual: your project's `google-services.json` in `android/app/`. `compileSdkVersion` 34 is enough.

### iOS

Add the **Push Notifications** capability, and set the deployment target to 14 or later in Xcode and, with CocoaPods, in `ios/App/Podfile` (`platform :ios, '14.0'`). With Capacitor 6's default of 13.0, `pod install` fails: the plugin's pod "required a higher minimum deployment target".

Xcode 27 builds only for iOS 15 or later, and Capacitor 6's own pods declare 13.0. With Xcode 27, set 15.0 in both places and raise the pods in the Podfile, as [`samples/plain/`](samples/plain/) does:

```ruby
post_install do |installer|
  assertDeploymentTarget(installer)
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      if config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'].to_f < 15.0
        config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
      end
    end
  end
end
```

With Swift Package Manager, the app gets the plugin from its `Package.swift`, which builds with Capacitor 6, 7 and 8. Capacitor 6's CLI (6.2.3) writes `exact: "6.2.3"` for `capacitor-swift-pm` into `ios/App/CapApp-SPM/Package.swift`. That version doesn't exist, so resolution fails until you change it to `6.2.2`.

In `ios/App/App/AppDelegate.swift`, forward the APNs token with the same lines every Capacitor push plugin requires:

```swift
func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    NotificationCenter.default.post(name: .capacitorDidRegisterForRemoteNotifications, object: deviceToken)
}

func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
    NotificationCenter.default.post(name: .capacitorDidFailToRegisterForRemoteNotifications, object: error)
}
```

The SDK requests the token itself. Data Talks sends through APNs with your app's own key, so the app needs no Firebase on iOS.

### iOS through Firebase

If your iOS app already sends through its own Firebase project, set the iOS transport to FCM in the portal and post the FCM token instead, as Capacitor's Firebase setup does:

```swift
import FirebaseMessaging

func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    Messaging.messaging().apnsToken = deviceToken
    Messaging.messaging().token { token, error in
        if let error {
            NotificationCenter.default.post(name: .capacitorDidFailToRegisterForRemoteNotifications, object: error)
        } else if let token {
            NotificationCenter.default.post(name: .capacitorDidRegisterForRemoteNotifications, object: token)
        }
    }
}
```

The plugin passes a posted string to the SDK as the FCM token. If the app gets the token in JavaScript instead, pass it with `DataTalksPush.setFcmToken({ token })`. On Android that call does nothing: the SDK reads the token itself. Until a token arrives, iOS registers nothing.

### Scenes, for Xcode 27

An app built with the iOS 27 SDK must use scenes. Without them, iOS terminates the app at launch, and the device log says "UIScene life cycle is required for apps built with this SDK", from `_UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption`. Capacitor's template adopts scenes from 8.5 ([its guide](https://capacitorjs.com/docs/updating/8-5)), with a `SceneDelegateProxy` that earlier versions lack. Before 8.5 (Capacitor 6 included), make two changes yourself, as [`samples/plain/`](samples/plain/) and [`samples/ionic-react/`](samples/ionic-react/) do:

1. Copy [`SceneDelegate.swift`](samples/plain/ios/App/App/SceneDelegate.swift) into `ios/App/App/`, and add it to the App target in Xcode. It builds the window from `Main.storyboard`, so a storyboard that names a `CAPBridgeViewController` subclass keeps working. If your `Info.plist`'s `UIMainStoryboardFile` names another storyboard, use that name in the file: with a wrong name, the app terminates at launch. With scenes, links arrive at the scene instead of the app delegate, and the scene delegate forwards them to Capacitor's `ApplicationDelegateProxy`, so `@capacitor/app`'s `appUrlOpen` and `getLaunchUrl` keep working.
2. In `ios/App/App/Info.plist`, replace the `UIMainStoryboardFile` entry with the scene manifest:

```xml
<key>UIApplicationSceneManifest</key>
<dict>
	<key>UIApplicationSupportsMultipleScenes</key>
	<false/>
	<key>UISceneConfigurations</key>
	<dict>
		<key>UIWindowSceneSessionRoleApplication</key>
		<array>
			<dict>
				<key>UISceneConfigurationName</key>
				<string>Default Configuration</string>
				<key>UISceneDelegateClassName</key>
				<string>$(PRODUCT_MODULE_NAME).SceneDelegate</string>
			</dict>
		</array>
	</dict>
</dict>
```

The plugin needs nothing more: the APNs token still reaches the app delegate's two lines, and Capacitor's router remains the notification center's delegate. Both demos are tested this way on an iOS 27.2 simulator with Xcode 27.2: the install registers its APNs token, and foreground pushes, taps in the background and taps that launch the app all reach the plugin. With `@capacitor/app` added to the plain demo, a link in the app's own scheme reaches `appUrlOpen` while the app is open, and both `appUrlOpen` and `getLaunchUrl` when the link launches it. Universal links are untested.

With scenes, iOS no longer calls these app delegate methods:

- `application(_:open:options:)`
- `application(_:continue:restorationHandler:)`
- `application(_:performActionFor:completionHandler:)` (Home Screen quick actions)
- `applicationDidBecomeActive`, `WillResignActive`, `DidEnterBackground` and `WillEnterForeground`

The launch options don't carry the URL, user activity or quick action that launched the app; the scene's connection options do. The app delegate's `window` stays `nil`. Move your own code that relies on any of this to the scene delegate (`windowScene(_:performActionFor:completionHandler:)` for quick actions), or to the `UIApplication` notifications, which are still posted.

Other plugins can break under scenes. Before Capacitor 8.2, `bridge.presentVC` shows a full-screen view in its own window, which belongs to no scene, so nothing appears ([Capacitor issue 5951](https://github.com/ionic-team/capacitor/issues/5951)). Of Capacitor 6's official plugins, only `@capacitor/browser` uses it: `Browser.open()` shows nothing unless given `presentationStyle: 'popover'`, which presents from Capacitor's view controller and still fills the screen on an iPhone. `@capacitor/inappbrowser` already presents from that view controller. Splash Screen, Keyboard, Screen Orientation and App find the scene's window themselves. To find plugins in your app that open views this way, or that look for the app delegate's window (`nil` under scenes), run:

```bash
grep -rlF -e presentVC -e 'UIWindow(frame:' -e 'UIWindow.init(frame:' -e 'UIWindow alloc] initWithFrame' -e 'delegate?.window' -e 'delegate] window' node_modules --include=*.swift --include=*.m
```

`@capacitor/ios` itself is always listed. Splash Screen and Keyboard are listed too, but work: when the app delegate has no window, they use the scene's. Check any other plugin listed.

## Another push plugin

This plugin must be the app's only push plugin. Two can't share the pushes:

- **Android:** Firebase delivers each message to one service. When another plugin's service receives them, pushes from Data Talks arrive but never show.
- **iOS:** Capacitor's notification router has one push handler, and the notification center one delegate. Taps, and pushes that arrive while the app is open, reach only one of them.

Remove the other plugin before you add this one: `npm uninstall` it, delete the code that calls it (its register call and its listeners), and run `npx cap sync`. When leaving OneSignal, also remove any OneSignal lines in `AppDelegate.swift` or `MainActivity`. Keep Capacitor's `ios.handleApplicationNotifications` on (the default).

If another one remains, a debug build logs it at startup with the class it found: in Logcat on Android, in Xcode's console on iOS. Capacitor's default `loggingBehavior` keeps release builds quiet. On iOS the check runs once, after every plugin has loaded, so it misses an SDK that the web app starts later:

| Log line starts with | What it found |
|---|---|
| `Another service receives Firebase messages: …` | Android: another service for Firebase's messages, such as `com.capacitorjs.plugins.pushnotifications.MessagingService`. A service of your own that forwards to `DataTalksPush.handleRemoteMessage` is reported too, and works; one that extends `DataTalksMessagingService` isn't reported |
| `Another push SDK receives Firebase messages: …` | Android: another SDK's receiver that reads them first, such as OneSignal's |
| `⚡️ DataTalksPush: another plugin is the push handler (…)` | iOS: a plugin that loaded after this one took Capacitor's push handler |
| `⚡️ DataTalksPush: another plugin was the push handler (…)` | iOS: a plugin that loaded before this one, which now gets nothing |
| `⚡️ DataTalksPush: the notification center's delegate isn't Capacitor's (…)` | iOS: an SDK took the notification center from Capacitor, or `handleApplicationNotifications` is off |

## Use

```ts
import { DataTalksPush } from '@datatalks-ab/push-capacitor';

await DataTalksPush.addListener('notificationOpened', ({ deepLink, data }) => {
  // Route to deepLink. A tap that started the app arrives here as soon as this listener is added.
});
await DataTalksPush.addListener('identityResult', ({ verified, errorCode }) => {
  // A refused identify isn't retried: call identify again at the next sign-in.
});

const { receive } = await DataTalksPush.requestPermissions(); // 'granted', 'denied' or 'prompt'

// After sign-in, with the token your backend signed for this user:
await DataTalksPush.identify({ externalId: String(user.id), identityToken });

await DataTalksPush.logout();
await DataTalksPush.setMarketingOptIn({ optIn: false });
await DataTalksPush.setFcmToken({ token }); // iOS through Firebase only, when the AppDelegate doesn't post the token
await DataTalksPush.deleteLocalData();
```

The calls resolve at once: the SDK does the work in the background and retries it. `identify` without an `identityToken` links the device unverified, and is refused when the push app requires verified identity.

With `openLinks` true (the default), the SDK opens a push's link as in a native app: an `https` link through the system, any other scheme inside the app. With `openLinks` false, a tap only opens the app, and the link reaches `notificationOpened`.

## Develop

`npm run vendor` copies the native SDKs into the package: the iOS sources the pod and the Swift package compile (`ios/Sources/DataTalksPushPlugin/Core`), and the Android SDK as a Maven repository (`android/maven`). It needs Java 17 or later in `JAVA_HOME`. `npm pack` runs it, then `npm run build`.

[`samples/plain/`](samples/plain/) is DT Capacitor, the [sample app](../../README.md#sample-apps) for this plugin: a Capacitor 6 app (compileSdk 34, minSdk 23), `se.datatalks.sandbox.capacitor` on both platforms. It has the two Android changes above and, on iOS, the app delegate lines, the Push Notifications entitlement, the Xcode 27 Podfile (iOS 15, CocoaPods) and scenes. Its page is plain HTML with no build step, and its key goes in `capacitor.config.json`. After `npm run vendor` and `npm run build` here:

```bash
cd samples/plain
npm install
npx cap sync
```

Then build `samples/plain/android` with Java 17: Capacitor 6's Gradle 8.2 doesn't run on Java 21. On a Mac, open `samples/plain/ios/App/App.xcworkspace`. A simulator gets an APNs token with the entitlement, and `xcrun simctl push` delivers a push to it. The page shows the permission and each event.

[`samples/ionic-react/`](samples/ionic-react/) is DT Ionic (`se.datatalks.sandbox.ionic`), the same demo on Ionic 6 with React 18, React Router 5 and Capacitor 6, built with Vite, with the same iOS changes, scenes included. Its `src/PushEvents.tsx` is the [guide's](guide-ionic-react.md) listener, and a push's link routes to `/tickets/:id`. It pins `@types/react` to 18.2.7, because Ionic 6's component types don't compile against 18.2.8 or later. Its key comes from the environment:

```bash
cd samples/ionic-react
npm install
npm run build
DATATALKS_PUSH_APP_KEY=dtpk_prd_... npx cap sync
```
