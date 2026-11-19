# Data Talks Push for Android

`se.datatalks:push-android`. Kotlin, `minSdk 23`, `firebase-messaging` 25.1.3 or later. It uses your app's own Firebase project.

## Start

```kotlin
class MyApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        DataTalksPush.initialize(this, "dtpk_prd_...")
    }
}
```

This registers the device on first launch and keeps the registration up to date. Your app needs Firebase set up as usual (`google-services.json`).

```kotlin
DataTalksPush.requestPermission(activity) { permission -> } // the Android 13 prompt, and its result
DataTalksPush.permissionStatus(context)                // AUTHORIZED, DENIED or NOT_DETERMINED
DataTalksPush.identify(externalId, email, identityToken) // after sign-in, with the token your backend signed; repeated the same day, it replays the earlier result
DataTalksPush.logout()
DataTalksPush.setMarketingOptIn(false)
DataTalksPush.deleteLocalData()                        // deletes the install too; the SDK stays off until the next initialize
```

These calls return immediately. The work runs in the background with WorkManager and is retried when the network or the service is back. `requestPermission` shows the prompt from a transparent SDK activity, so the result reaches the callback without your activity forwarding `onRequestPermissionsResult`.

To receive results, set a listener in `Application.onCreate`. A tap that arrives before any listener is set (for example one that launches the app before a wrapper has loaded) is held for the first listener; only the most recent one is kept.

```kotlin
DataTalksPush.setListener(object : DataTalksPushListener {
    override fun onNotificationOpened(deepLink: String?, data: JSONObject?) { /* ... */ }
    override fun onMessageReceived(message: DataTalksMessage) { /* ... */ }
    override fun onIdentityResult(result: DataTalksIdentityResult) { /* a refused identify isn't retried */ }
})
```

## Token or Firebase Installation ID

Firebase addresses a device either by registration token or by Firebase Installation ID (FID), and an app uses one or the other. The SDK follows your app's choice and never makes it.

| Your manifest | The SDK uses | Sends as |
|---|---|---|
| No flag (the default) | `getToken()` and `onNewToken` | `fcm_token` |
| `firebase_messaging_installation_id_enabled` set to `true` | `register()` and `onRegistered` | `fcm_fid` |

```xml
<meta-data android:name="firebase_messaging_installation_id_enabled" android:value="true" />
```

**Turning the flag on affects every sender of your app.** Within seconds of the update the app's registration token stops working and `getToken()` fails, for other libraries and your own backend too. Turn it on only when Data Talks is the only sender, or when every other sender has moved to the FID. Firebase has deprecated the token APIs but announced no removal date.

`firebase-messaging` before 25.1.0 ignores the flag, so the SDK uses the token. On `firebase-messaging` 26.x, Firebase itself requires `minSdk 24`.

## An app with its own messaging service

Android delivers Firebase's callbacks to a single service. If your app declares its own `FirebaseMessagingService`, the SDK's is not called, so forward to the SDK:

```kotlin
class MyMessagingService : FirebaseMessagingService() {
    override fun onMessageReceived(message: RemoteMessage) {
        if (DataTalksPush.handleRemoteMessage(this, message)) return
        // Not from Data Talks: yours to handle.
    }

    override fun onNewToken(token: String) {
        DataTalksPush.onNewRegistration(this, token)
    }

    override fun onRegistered(installationId: String) {
        DataTalksPush.onNewRegistration(this, installationId)
    }
}
```

Or extend `DataTalksMessagingService` and call `super`. Don't use intent-filter priorities: the service that loses receives nothing.

## Notifications

The SDK renders a push with `NotificationCompat`. Set these in your manifest:

| `meta-data` | Value | Without it |
|---|---|---|
| `se.datatalks.push.notification_icon` | A drawable: the small icon, a white shape on transparent | `com.google.firebase.messaging.default_notification_icon`, then your app's icon |
| `se.datatalks.push.notification_color` | A colour resource | `com.google.firebase.messaging.default_notification_color` |
| `se.datatalks.push.notification_channel_name` | The default channel's name | The string `datatalks_push_default_channel_name`, "Notifications" |

Android draws the small icon from its alpha channel only, so a full-colour icon shows as a solid shape. Use a white shape on a transparent background, 24 dp, as a vector drawable or as PNGs from 24 to 96 px.

The push app's settings in the Data Talks portal can also set an accent colour and a large icon (your logo in full colour, at the right of the notification). Every push then carries them: the colour overrides the manifest's, and the large icon is downloaded with the push, alongside its picture. The small icon can't be set this way; it must be a drawable in your app.

### Delivery, opens and clicks

The SDK reports what happens to each push, so it shows in the campaign's results:
- **delivery:** when the SDK shows the push and notifications are enabled for the app and the channel;
- **open:** on a tap;
- **click:** on the same tap, when the push has a link, whether the SDK opens it or your app does (`openLinks = false`).

A tap on a push that Android displayed itself (on a device your backend registered, while the app was in the background)
launches the app with the push's keys in the intent; the SDK reports that open too, from the activity callbacks `initialize` registers.

Events are queued on the device (at most 200, for up to 30 days) and sent with the next sync, which WorkManager runs when a
network is available. They carry the push's id, the time and, for a click, the link; nothing about the person or the device.

A push can name a channel your app created. A channel that doesn't exist falls back to the default one, `datatalks_default`.

A tap opens the push's link, or your launcher activity when there is none. An `https` link goes through the system, so your verified App Links work; any other scheme opens only inside your app. An app that routes links itself, such as a web-view app, passes `DataTalksPushOptions(openLinks = false)`: a tap then opens the launcher and the link goes to `onNotificationOpened`. The SDK persists this option, so it also applies to a tap that launches the app before `initialize`.

The SDK depends on WorkManager 2.9, which an app compiling against API 34 can use; 2.10 and later require API 35. An app on a newer WorkManager keeps its own version.

Android delivers nothing to an app the user force-stopped, and shows nothing while notifications are off. FCM still reports success to the sender in both cases.

## The sample

`samples/compose` is DT Native for Android, one of the [sample apps](../../README.md#sample-apps). It covers the app key, registration, the permission, identify, logout, consent, delete, and the events the SDK reports.

1. Put your Firebase project's `google-services.json` in `samples/compose/`. It stays out of git. The package is `se.datatalks.sandbox`.
2. Run `./gradlew :samples:compose:installDebug`. Add `-PfidMode=true` for an app in FID mode.
3. Paste an app key and, optionally, an identity token from the portal's **Test a token**.

## Tests

```bash
./gradlew :push:testDebugUnitTest
```

The unit tests replay [`spec/fixtures`](../../spec/fixtures) against a mock server and validate the request bodies against the OpenAPI document.

With an emulator running:

```bash
./gradlew :push:connectedDebugAndroidTest
```

To also run the full device flow against a local ingress, pass its URL and an app key:

```bash
./gradlew :push:connectedDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.baseUrl=http://10.0.2.2:5000/v1 -Pandroid.testInstrumentationRunnerArguments.appKey=dtpk_stg_...
```
