# Data Talks Push for .NET MAUI

`DataTalks.Push.Maui` wraps the [Android](../android/README.md) and [iOS](../ios/README.md) SDKs in one C# API with the same behaviour. It needs Android 6 (API 23) or later, iOS 15 or later, and .NET 10.

Read the native READMEs too: what they say about Firebase's two modes, notification icons, links and retries applies here.

## Start

```csharp
using DataTalks.Push.Maui;

public static MauiApp CreateMauiApp()
{
    var builder = MauiApp.CreateBuilder();
    builder
        .UseMauiApp<App>()
        .UseDataTalksPush("dtpk_prd_...");

    return builder.Build();
}
```

On iOS, derive the `AppDelegate` from `DataTalksPushApplicationDelegate`. MAUI has no lifecycle events for the APNs callbacks, so this class forwards the token:

```csharp
[Register("AppDelegate")]
public class AppDelegate : DataTalksPushApplicationDelegate
{
    protected override MauiApp CreateMauiApp() => MauiProgram.CreateMauiApp();
}
```

If your `AppDelegate` can't change its base class, export the two selectors yourself and forward them to `DataTalksPush.DidRegisterForRemoteNotifications` and `DidFailToRegisterForRemoteNotifications`.

An app built with the iOS 27 SDK must use scenes, or iOS stops it at launch. In `Info.plist`, under `UIApplicationSceneManifest`, add a scene configuration named `__MAUI_DEFAULT_SCENE_CONFIGURATION__` (the name MAUI looks for) with a delegate class derived from `MauiUISceneDelegate`, as the sample does. The SDK needs nothing from the scene: the APNs callbacks and the notification delegate stay with the app.

With scenes, a link in your own scheme that the SDK opens goes to the scene, so handle it in the `SceneOpenUrl` lifecycle event, not `OpenUrl`. Checked with the sample on an iOS 27 simulator: the token, a push while the app is open, a tap in the background, and a tap that launches the app.

Your app also needs:
- **Android:** Firebase set up, with your `google-services.json` as a `GoogleServicesJson` item. That item needs the `Xamarin.GooglePlayServices` build task, which `Xamarin.Firebase.Messaging` brings.
- **iOS:** the `aps-environment` entitlement, and a provisioning profile with Push Notifications.
- **An iOS simulator:** on a Mac with Apple silicon or a T2 chip, it gets a real APNs token when the build has `aps-environment`. A custom entitlements file also needs a `keychain-access-groups` entry, `$(AppIdentifierPrefix)$(CFBundleIdentifier)`; without it a simulator build can't use the Keychain, so the SDK warns and registers a new install at every launch. The sample's `Entitlements.plist` has both, and its simulator builds are signed ad hoc (`CodesignKey` `-`), which needs no profile.

## Calls

```csharp
var permission = await DataTalksPush.RequestPermissionAsync(); // the Android 13 prompt, or alert, sound and badge on iOS
var status = await DataTalksPush.GetPermissionStatusAsync();   // Authorized, Denied, NotDetermined; on iOS also Provisional and Ephemeral
DataTalksPush.Identify(externalId, email, identityToken);      // after sign-in, with the token your backend signed; a repeat that day only replays the answer
DataTalksPush.Logout();
DataTalksPush.SetMarketingOptIn(false);
DataTalksPush.SetFcmToken(token);                              // iOS through Firebase only; does nothing on Android
DataTalksPush.DeleteLocalData();                               // deletes the install too; the SDK stays off until the next Initialize

DataTalksPush.NotificationOpened += (_, e) => Open(e.DeepLink, e.DataJson);
DataTalksPush.MessageReceived += (_, e) => Show(e.Title, e.Body); // on iOS, only while the app is open
DataTalksPush.IdentityResult += (_, e) => Log(e.Verified, e.ErrorCode, e.ErrorDetail);
```

`RequestPermissionAsync` returns the user's answer. Where no prompt can show (the permission is already granted, Android is older than 13, or no activity is on screen), it returns the current status. `RequestPermissionAsync(provisional: true)` asks iOS for provisional authorization: no prompt, and pushes are delivered quietly.

A tap that arrives before anything subscribes to `NotificationOpened`, such as the one that launched the app, is kept: the newest one is delivered once, to the first handler that subscribes. A page can therefore subscribe when it is created. `DataJson` is the push's data as a JSON object, for your own parser.

A push's link opens as in a native app: an `https` link through the system, any other scheme inside the app. An app that routes links itself turns this off and gets the link only from `NotificationOpened`:

```csharp
builder.UseDataTalksPush("dtpk_prd_...", new DataTalksPushOptions(OpenLinks: false));
```

## An app that already receives pushes

**Android.** Firebase delivers each message to one `FirebaseMessagingService`: the first in the manifest, unless an intent filter has a higher priority. If your app declares one, give it priority 1 so it comes before the SDK's and any library's, and forward to the SDK:

```csharp
[Service(Exported = false)]
[IntentFilter(new[] { "com.google.firebase.MESSAGING_EVENT" }, Priority = 1)]
public class AppMessagingService : FirebaseMessagingService
{
    public override void OnMessageReceived(RemoteMessage message)
    {
        if (DataTalksPush.HandleRemoteMessage(this, message)) return;
        // Not from Data Talks: yours to handle.
    }

    public override void OnNewToken(string token) => DataTalksPush.OnNewRegistration(this, token);
}
```

**iOS.** `UseDataTalksPush` makes the SDK the notification delegate; it passes other notifications on to the delegate set before it. To keep your own delegate, pass `ownNotificationDelegate: true` to `UseDataTalksPush` and forward to `HandleWillPresent` and `HandleNotificationResponse`.

### With Plugin.Firebase

`Plugin.Firebase.CloudMessaging` declares its own service, which comes before the SDK's. Without a service of your own, the SDK never receives Data Talks pushes, so it neither shows nor reports them. Derive your service from the plugin's so its messages still reach it:

```csharp
[Service(Exported = false)]
[IntentFilter(new[] { "com.google.firebase.MESSAGING_EVENT" }, Priority = 1)]
public class AppMessagingService : Plugin.Firebase.CloudMessaging.Platforms.Android.MyFirebaseMessagingService
{
    public override void OnMessageReceived(RemoteMessage message)
    {
        if (DataTalksPush.HandleRemoteMessage(this, message)) return;
        base.OnMessageReceived(message);
    }

    public override void OnNewToken(string token)
    {
        DataTalksPush.OnNewRegistration(this, token);
        base.OnNewToken(token);
    }
}
```

Plugin.Firebase needs `Xamarin.Firebase.Messaging` 124.0.0.2 or later and the SDK needs 125.1.3, so both get 125.1.3. Reference that version directly; your app needs the reference anyway for the `google-services.json` build task. If a later Plugin.Firebase needs a newer version, NuGet reports a downgrade until you raise yours.

On iOS, `FirebaseCloudMessagingImplementation.Initialize()` makes Plugin.Firebase the notification delegate. Call it before `UseDataTalksPush` starts the SDK, as its usual setup in `WillFinishLaunching` does; the SDK then passes it every notification that isn't from Data Talks. If it is called later, it takes over the delegate and taps on Data Talks pushes go to Plugin.Firebase instead.

Checked with Plugin.Firebase.CloudMessaging 4.0.1.

### iOS through Firebase

If your iOS app sends through its own Firebase project too, set the iOS transport to FCM in the portal and pass the FCM token on. With Plugin.Firebase:

```csharp
CrossFirebaseCloudMessaging.Current.TokenChanged += (_, e) => DataTalksPush.SetFcmToken(e.Token);
DataTalksPush.SetFcmToken(await CrossFirebaseCloudMessaging.Current.GetTokenAsync());
```

On Android the call does nothing: the SDK reads the token itself. On iOS, the SDK registers nothing until a token arrives. See the [iOS README](../ios/README.md#apps-that-send-through-firebase).

## Pictures and delivery receipts (iOS)

By default, iOS shows only a push's text, and Data Talks counts a push as delivered when it is opened. A Notification Service Extension shows the picture and reports the delivery as soon as the push arrives, whether the app is running or not. The extension is native: an Xcode project next to the MAUI app, which the MAUI build copies into the app.

1. In Xcode, create an iOS project with a **Notification Service Extension** target named `NotificationService`, bundle id `<your app id>.NotificationService`, deployment target 15. Add the `DataTalksPushExtension` product of the iOS SDK's Swift package to that target (not `DataTalksPush`: an extension can't link the app's SDK), and replace the generated class with:

   ```swift
   import DataTalksPushExtension

   class NotificationService: DataTalksNotificationService {}
   ```

2. Give the app and the extension the same App Group, for example `group.com.example.app`: in the extension's entitlements, in the app's `Platforms/iOS/Entitlements.plist` (`com.apple.security.application-groups`), and in the Apple Developer account for both App IDs. Add the group's name to both Info.plists, the app's `Platforms/iOS/Info.plist` and the extension's:

   ```xml
   <key>DataTalksAppGroup</key>
   <string>group.com.example.app</string>
   ```

3. Build the extension for the device and the simulator, signed with the extension's own profile:

   ```bash
   xcodebuild -project NotificationService/NotificationService.xcodeproj -scheme NotificationService -configuration Release -sdk iphoneos -derivedDataPath NotificationService/build
   xcodebuild -project NotificationService/NotificationService.xcodeproj -scheme NotificationService -configuration Release -sdk iphonesimulator -derivedDataPath NotificationService/build
   ```

4. Embed it from the app's `.csproj`:

   ```xml
   <ItemGroup Condition="$(TargetFramework.Contains('-ios'))">
     <AdditionalAppExtensions Include="$(MSBuildProjectDirectory)/NotificationService/build/Build/Products">
       <Name>NotificationService</Name>
       <BuildOutput Condition="'$(SdkIsSimulator)' == 'false'">Release-iphoneos</BuildOutput>
       <BuildOutput Condition="'$(SdkIsSimulator)' == 'true'">Release-iphonesimulator</BuildOutput>
       <CodesignEntitlements>NotificationService/NotificationService/NotificationService.entitlements</CodesignEntitlements>
     </AdditionalAppExtensions>
   </ItemGroup>
   ```

   The app bundle then contains `PlugIns/NotificationService.appex`. Rebuild the extension after an SDK update: the MAUI build only copies what is already built.

Use a group that only the app and its extension share. Without the group, or with its name in only one Info.plist, the picture still shows but deliveries are counted on open. Pictures must be `https` JPEG, PNG or GIF, at most 5 MB, and download within 10 seconds. `xcrun simctl push` doesn't run a service extension, so test pictures and receipts with a push from Data Talks on a device.

## Building it

The binding projects wrap two native builds, which aren't in git:

```bash
sdks/maui/build-native.sh
```

It writes to `sdks/maui/native/artifacts/`: the Android library on any machine, the iOS framework only on a Mac. Run it again after a change to `sdks/android/push`, `sdks/ios/Sources` or `sdks/maui/native/ios`. Then:

```bash
dotnet build sdks/maui/samples/maui-app -f net10.0-android
```

On a Mac, for a simulator:

```bash
dotnet build sdks/maui/samples/maui-app -p:TargetFrameworks=net10.0-ios -p:RuntimeIdentifier=iossimulator-arm64
```

The sample targets iOS only on a Mac; on Windows it builds for Android only.

## Tests

```bash
dotnet test sdks/maui/tests/DataTalks.Push.Maui.Tests
```

They compile the wrapper's shared code against a fake platform, so they need no MAUI workload and no device. They cover the options, the permission names, the tap kept for the first handler, and what each event carries. The platform code is covered by CI builds of the sample for Android and iOS.

## Packaging

The wrapper ships as three packages with one version, set in `sdks/maui/Directory.Build.props`: `DataTalks.Push.Maui` and the two bindings it depends on, `DataTalks.Push.Android.Binding` and `DataTalks.Push.iOS.Binding`. After `build-native.sh`:

```bash
sdks/maui/pack.sh
```

It writes the packages locally, to `sdks/maui/native/artifacts/nupkg/`. It needs the iOS framework, so run it on a Mac, or on Windows with `native/artifacts/DataTalksPushBridge.xcframework` copied from a Mac; without the framework the wrapper would ship without iOS, so the script stops. Copy the framework again after any change to `sdks/ios/Sources` or `sdks/maui/native/ios`: a stale copy still packs, and fails only at run time on iOS. `-p:Version=...` overrides the version.

CI publishes the packages to nuget.org on a release tag (see [RELEASING.md](../../RELEASING.md)).

## The sample

`samples/maui-app` is DT MAUI, one of the [sample apps](../../README.md#sample-apps): app key input, register, permission, identify, logout, consent, delete, and a log of what the SDK reports. Its id is `se.datatalks.sandbox.maui` on both platforms.

**Android:** put your Firebase project's `google-services.json` in the sample's folder.

**iOS:** a simulator needs nothing else; it gets a real APNs token on a Mac with Apple silicon or a T2 chip. For a device, build with `-p:RuntimeIdentifier=ios-arm64` and a provisioning profile for `se.datatalks.sandbox.maui` with Push Notifications.

## How it fits together

| Project | What |
|---|---|
| `src/DataTalks.Push.Android.Binding` | C# for `push-android`, generated from the library |
| `native/ios` | `DataTalksPushBridge.framework`: the iOS SDK's sources plus an Objective-C layer, because a .NET binding can't read a Swift-only API. It holds no logic of its own |
| `src/DataTalks.Push.iOS.Binding` | C# for that framework, written by hand in `ApiDefinition.cs` |
| `src/DataTalks.Push.Maui` | The API above |
| `tests/DataTalks.Push.Maui.Tests` | The wrapper's shared code against a fake platform; see [Tests](#tests) |
