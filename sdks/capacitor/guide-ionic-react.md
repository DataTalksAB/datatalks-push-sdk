# Data Talks Push in an Ionic React app

How to add `@datatalks/push-capacitor` to an Ionic React app on Capacitor 6, step by step: what to remove first, the changes to the Android and iOS projects, the React code, and the identity token your backend signs. [README.md](README.md) is the reference for each piece.

The plugin accepts Capacitor 6 to 8. It has been built and run in Capacitor 6 apps, and its iOS part also compiles against Capacitor 7 and 8. Step 4 assumes CocoaPods, Capacitor 6's default; with Swift Package Manager there is no Podfile, and the app gets the plugin from its `Package.swift` instead ([README](README.md#ios)).

## What you need

From your push app in the Data Talks portal:

- **An app key per build.** A test key (`dtpk_prd_test_…`) for your test builds and a live key (`dtpk_prd_live_…`) for the store build. The key also picks the host, so nothing else is configured.
- **The App ID and an identity secret,** from the push app's **Identity** tab. Your backend signs identity tokens with them (see [Identity tokens](#identity-tokens)). The secret is shown once: store it with your backend's other secrets.
- **Your Firebase project's `google-services.json`** for the app's Android package, and **your APNs key** uploaded to the push app for iOS.

And in the app: Android `minSdkVersion` 23 or later, and iOS 14 or later (15 when you build with Xcode 27).

To see the SDK at work before you change your app, run DT Ionic, the sandbox demo in [`samples/ionic-react/`](samples/ionic-react/), with your test key. It is an Ionic 6 app with this guide's code: a tap on a push with the link `myapp://tickets/1042` opens its ticket page. On Ionic 6, keep `@types/react` at 18.2.7: from 18.2.8, Ionic 6's components don't type-check.

## 1. Take out your current push plugin

The plugin replaces any other push plugin: Android delivers Firebase messages to one service, and Capacitor's iOS router has one push handler ([why](README.md#another-push-plugin)). Before you install it:

```bash
npm uninstall @capacitor/push-notifications   # or onesignal-cordova-plugin, @onesignal/..., and so on
```

Then delete the code that used it: the `PushNotifications.register()` call and its `registration`, `pushNotificationReceived` and `pushNotificationActionPerformed` listeners, or OneSignal's `initialize` and its handlers. If you added lines for it to `AppDelegate.swift` or `MainActivity`, delete those too, except the two APNs lines in step 4, which this plugin needs as well.

If one remains, a debug build logs it at startup, with the class it found.

## 2. Install and configure

```bash
npm install @datatalks/push-capacitor   # or, from a packed tarball: npm install ./datatalks-push-capacitor-<version>.tgz
npx cap sync
```

`capacitor.config.ts` is read by `npx cap sync`, so it can pick the key from the environment you build for:

```ts
const config: CapacitorConfig = {
  // ...
  plugins: {
    DataTalksPush: {
      appKey: process.env.DATATALKS_PUSH_APP_KEY, // dtpk_prd_test_… or dtpk_prd_live_…
      openLinks: false,
    },
  },
};
```

With `openLinks: false`, your app handles a push's link: a tap opens the app, and the link goes to your `notificationOpened` listener, which passes it to the Ionic router (step 5). With the default, `true`, the SDK opens the link itself, as in a native app.

## 3. Android

In `android/variables.gradle`, set `minSdkVersion = 23`. Capacitor 6's template sets 22, which fails the build with a manifest merger error.

In `android/build.gradle`, add the repository that ships the Android SDK inside the npm package:

```groovy
allprojects {
    repositories {
        google()
        mavenCentral()
        maven { url "${project(':datatalks-push-capacitor').projectDir}/maven" }
    }
}
```

Put `google-services.json` in `android/app/`, as for any Firebase app. Optionally, give the notifications your own small icon (white on transparent) and colour, in `android/app/src/main/AndroidManifest.xml` inside `<application>`:

```xml
<meta-data android:name="se.datatalks.push.notification_icon" android:resource="@drawable/ic_stat_notification" />
<meta-data android:name="se.datatalks.push.notification_color" android:resource="@color/notification" />
```

## 4. iOS

In Xcode (`npx cap open ios`), add the **Push Notifications** capability to the App target, and set the deployment target to 14, or 15 with Xcode 27. In `ios/App/Podfile`, set the same in `platform :ios, '14.0'`. With Xcode 27, also raise Capacitor's own pods, which declare 13: [the Podfile lines](README.md#ios).

In `ios/App/App/AppDelegate.swift`, forward the APNs token. Every Capacitor push plugin requires these two methods, so they may already be there:

```swift
func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    NotificationCenter.default.post(name: .capacitorDidRegisterForRemoteNotifications, object: deviceToken)
}

func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
    NotificationCenter.default.post(name: .capacitorDidFailToRegisterForRemoteNotifications, object: error)
}
```

iOS needs no Firebase: Data Talks sends through APNs with your key.

**With Xcode 27, add scenes.** An app built with the iOS 27 SDK must use them, or iOS terminates it right after the launch screen. Capacitor 6's template has none, so add them yourself, as DT Ionic does:

1. Copy [`SceneDelegate.swift`](samples/ionic-react/ios/App/App/SceneDelegate.swift) into `ios/App/App/`, and add it to the App target in Xcode. It builds the window from `Main.storyboard` (change the name if your `UIMainStoryboardFile` differs), and forwards links to Capacitor, as `AppDelegate.swift` does without scenes.
2. In `ios/App/App/Info.plist`, replace `UIMainStoryboardFile` with the scene manifest from [the README](README.md#scenes-for-xcode-27).

The plugin needs nothing else for scenes. Your own code in `AppDelegate.swift`'s `application(_:open:options:)`, `application(_:continue:restorationHandler:)` or the active and background methods no longer runs, and must move to the scene delegate: [the README](README.md#scenes-for-xcode-27) says where.

Other plugins may need a change too. On Capacitor 6, `@capacitor/browser`'s `Browser.open()` shows nothing under scenes until it gets `presentationStyle: 'popover'`. [The README](README.md#scenes-for-xcode-27) explains why, and has a command that finds other plugins with the same problem.

### Pictures and delivery receipts (optional)

By default, iOS shows only a push's text, and Data Talks counts a push as delivered when it is opened. A Notification Service Extension shows the picture, and reports the delivery as soon as the push arrives, whether the app is running or not. The package ships it as a second pod (and Swift package product), `DataTalksPushExtension`, without Capacitor: an extension can't link the app's runtime.

1. In Xcode, **File → New → Target… → Notification Service Extension**, named `NotificationService`, with the same deployment target as the App (15 with Xcode 27). Xcode offers to activate its scheme: either answer works.
2. Replace the generated `NotificationService.swift` with this, and nothing more:

   ```swift
   import DataTalksPushExtension

   class NotificationService: DataTalksNotificationService {}
   ```

3. **On CocoaPods**, give the new target its pod in `ios/App/Podfile`, after the `target 'App'` block. Capacitor's CLI rewrites only the App target's pods, so this stays:

   ```ruby
   target 'NotificationService' do
     pod 'DatatalksPushExtension', :path => '../../node_modules/@datatalks/push-capacitor'
   end
   ```

   Then `npx cap sync ios`. **On Swift Package Manager**, select the `NotificationService` target, and under **General → Frameworks and Libraries** add `DataTalksPushExtension` from the `DatatalksPushCapacitor` package.
4. Give the App and the extension the same App Group (**Signing & Capabilities → + Capability → App Groups**, for example `group.com.example.app`), and name it in both `ios/App/App/Info.plist` and `ios/App/NotificationService/Info.plist`:

   ```xml
   <key>DataTalksAppGroup</key>
   <string>group.com.example.app</string>
   ```

   Use a group only the app and its extension share. Without the group, or with the name in one Info.plist only, the picture still shows, and deliveries are counted on open.
5. The extension needs an App ID and a provisioning profile of its own (`<your bundle id>.NotificationService`), with the same App Group, in the Apple Developer account.

Pictures are `https` JPEG, PNG or GIF, at most 5 MB, downloaded within 10 seconds; a picture that takes longer is left out. `xcrun simctl push` doesn't run a service extension, so check pictures and receipts with a push from Data Talks, on a device.

## 5. In the app

The SDK starts on its own when the app launches, from the key in the config: it registers the device and keeps the registration current. Your code adds four things.

**Taps and identify answers.** Listen once, near the top of the app, inside `IonReactRouter` so the listener can route. A tap that started the app is kept until this listener is added, so it isn't lost while the app loads.

```tsx
import { useEffect, useRef } from 'react';
import { useIonRouter } from '@ionic/react';
import { DataTalksPush } from '@datatalks/push-capacitor';

export function PushEvents() {
  // useIonRouter returns a new object on every render: a ref keeps the latest, so the listeners are added only once.
  const ionRouter = useIonRouter();
  const router = useRef(ionRouter);
  useEffect(() => {
    router.current = ionRouter;
  });

  useEffect(() => {
    const opened = DataTalksPush.addListener('notificationOpened', ({ deepLink }) => {
      const route = deepLink ? routeFor(deepLink) : undefined;
      if (route) router.current.push(route);
    });
    const identity = DataTalksPush.addListener('identityResult', ({ errorCode, errorDetail }) => {
      if (errorCode) console.warn('Data Talks refused the identify', errorCode, errorDetail);
    });
    return () => {
      opened.then((handle) => handle.remove());
      identity.then((handle) => handle.remove());
    };
  }, []);

  return null;
}

// https://app.example.com/tickets/1042 and myapp://tickets/1042 both become /tickets/1042; a link that isn't a URL leaves
// the app where it opened. A custom scheme is parsed as https because older WebViews don't split it into host and path
// (`new URL('myapp://tickets/1042').host` is empty there). Leading slashes collapse to one: a path starting with // would
// name another host, which the router refuses.
function routeFor(deepLink: string): string | undefined {
  try {
    const url = /^https?:/i.test(deepLink) ? new URL(deepLink) : new URL(deepLink.replace(/^[a-z][a-z0-9+.-]*:\/*/i, 'https://app/'));
    return '/' + url.pathname.replace(/^\/+/, '') + url.search;
  } catch {
    return undefined;
  }
}
```

**The permission.** Ask at a moment that explains itself, such as after sign-in or from a settings switch, rather than at the first launch. `checkPermissions` says where things stand without asking.

```ts
const { receive } = await DataTalksPush.requestPermissions(); // 'granted', 'denied' or 'prompt'
```

**Sign-in and sign-out.** After your own sign-in, and at each app start while the user is signed in, get a fresh identity token from your backend and identify:

```ts
const { identityToken } = await api.post('/push/identity-token'); // your endpoint, see below
await DataTalksPush.identify({ externalId: String(user.id), identityToken });
```

The SDK sends the same identify at most once a UTC day for this install: the same `externalId` and `email` again that day, with or without a token as before, send nothing, and the `identityResult` event repeats that day's answer. After a sign-out, a refused identify, a different user, or adding or dropping the token, the next identify is sent. An identify with only a token (no `externalId` or `email`) is always sent.

```ts
await DataTalksPush.logout(); // at sign-out: the device stays registered, without the user
```

**Consent and deletion.** If the app has its own switch for marketing messages, pass it on with `DataTalksPush.setMarketingOptIn({ optIn })`. When the user deletes their account, `DataTalksPush.deleteLocalData()` deletes this install on the service and on the device.

The calls resolve at once: the SDK does the work in the background and retries it when the network comes back. Answers come as events.

## Identity tokens

A token tells Data Talks that your backend vouches for who the user is, so a verified identify can't be forged from the app. It is a JWT that your backend signs at sign-in:

| Part | Value |
|---|---|
| Algorithm | HS256, and only HS256 |
| Key | The push app's identity secret, as UTF-8 text |
| `sub` | Your id for the user, as a string even when it is a number: the same value as `externalId` in `identify` |
| `email` | Optional: the user's email address |
| `aud` | The push app's App ID |
| `iat` | When you signed it |
| `exp` | At most 10 minutes after `iat` |

With Node and [`jsonwebtoken`](https://www.npmjs.com/package/jsonwebtoken), which adds `iat` itself:

```js
import jwt from 'jsonwebtoken';

// Only for the user who is signed in on this request.
app.post('/push/identity-token', requireSignIn, (req, res) => {
  const identityToken = jwt.sign(
    { sub: String(req.user.id), email: req.user.email }, // a number in sub is refused
    process.env.DATATALKS_IDENTITY_SECRET,
    { algorithm: 'HS256', audience: process.env.DATATALKS_PUSH_APP_ID, expiresIn: '5m' },
  );
  res.json({ identityToken });
});
```

The secret never goes into the app. Leave out `kid`: the service tries each of the app's current secrets, so rotating the secret in the portal needs no change here until the old one is retired. A clock difference of up to a minute is accepted.

When the service refuses a token, the `identityResult` event has `errorCode` `identity_token_invalid` and an `errorDetail` such as `expired`, `bad_signature`, `wrong_audience`, `lifetime_too_long` or `claims_mismatch` (the `externalId` or `email` you passed differs from the token's). A refused identify isn't retried: the next sign-in or app start sends a new token. The portal's **Test a token**, on the same **Identity** tab, checks a token from your backend and says what is wrong with it.

## Try it

1. Build with the test key, and run on a device: Android, and iOS with a development profile that has push.
2. Sign in and allow notifications. An `identityResult` event without an `errorCode` means the identify was accepted, and `verified: true` that your token counted. Data Talks links the device to the user's profile afterwards, in the background.
3. From the portal, send a push with a link to the user you signed in as: once with the app open (a `messageReceived` event), once with it in the background, and once with it closed. Each tap should route to the link.
4. Sign out, and send again: the push should no longer reach the user on that device.

## When something is off

| What you see | Look at |
|---|---|
| The build stops with a manifest merger error about `minSdkVersion` | Step 3: `minSdkVersion = 23` |
| Android can't resolve `se.datatalks:push-android` | Step 3: the `maven { url … }` line |
| `pod install` says the pod "required a higher minimum deployment target" | Step 4: iOS 14, or 15 with Xcode 27 |
| Built with Xcode 27, the iOS app shows its launch screen and then closes | Step 4: scenes |
| With scenes, `Browser.open()` or another plugin's screen never shows on iOS | Step 4: `presentationStyle: 'popover'`; for other plugins, the README's `presentVC` check |
| Pushes arrive on Android but never show | The log: another push plugin's service is still there (step 1) |
| Taps on iOS do nothing | The log: another push handler or notification delegate (step 1) |
| iOS never registers | The Push Notifications capability, and the two `AppDelegate` lines |
| `capacitor.config has no plugins.DataTalksPush.appKey` in the log | Step 2, then `npx cap sync` |
| `identityResult` with `identity_token_required` | The push app requires verified identity: send a token |
