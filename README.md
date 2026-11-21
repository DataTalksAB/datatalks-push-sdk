# Data Talks Push SDKs

Client SDKs for push notifications sent with [Data Talks](https://datatalks.se): Android, iOS, .NET MAUI and Capacitor.

**Status: `1.0.0-rc.3`,** the release candidate for 1.0.

| SDK | Folder | Install |
|---|---|---|
| Android (Kotlin) | [sdks/android](sdks/android) | `implementation("se.datatalks:push-android:1.0.0-rc.3")` from Maven Central |
| iOS (Swift) | [sdks/ios](sdks/ios) | Swift Package Manager: `https://github.com/DataTalksAB/datatalks-push-sdk`, from `1.0.0-rc.3` |
| .NET MAUI | [sdks/maui](sdks/maui) | `dotnet add package DataTalks.Push.Maui --version 1.0.0-rc.3` |
| Capacitor | [sdks/capacitor](sdks/capacitor) | `npm install @datatalks-ab/push-capacitor@1.0.0-rc.3` |

Each SDK's README covers set-up, the API and its sample app. For an Ionic React app, follow
[the Ionic React guide](sdks/capacitor/guide-ionic-react.md). React Native and Flutter SDKs come later.

## How it works

1. Create a push app in the Data Talks portal and copy its app key (`dtpk_prd_…`). Every build of the app uses the same
   key. If you need a sandbox environment, contact the Data Talks team.
2. Start the SDK with the key when the app launches. It registers the device and keeps the registration current.
3. When a user signs in, identify them; when they sign out, log out. An app that requires verified identity passes an
   identity token signed by its backend.
4. Send campaigns from Data Talks. The SDK shows them, opens their links and reports deliveries, opens and clicks. To
   try a push first, add your phone on the push app's Test devices tab and send a test.

## Repository

| Folder | What |
|---|---|
| [sdks/](sdks/) | One folder per SDK, with its tests and sample apps |
| [spec/](spec/) | The API between the SDKs and the service: OpenAPI, push payload, test scenarios |
| [tools/](tools/) | The sample apps' icons |

`Package.swift` sits at the root because Swift Package Manager only reads it there; the iOS code is in `sdks/ios`.

## Sample apps

One small app per framework, each on Android and iOS, to try a push app's key and to show the SDK's calls in code.
They share Data Talks' colours, a SANDBOX badge, and the same sections: app, user, device and events.

| App | Framework | Folder | Package and bundle id | Key |
|---|---|---|---|---|
| DT Native | Kotlin with Compose, Swift with SwiftUI | [sdks/android/samples/compose](sdks/android/samples/compose), [sdks/ios/samples/swiftui](sdks/ios/samples/swiftui) | `se.datatalks.sandbox` | Typed on the screen |
| DT MAUI | .NET MAUI | [sdks/maui/samples/maui-app](sdks/maui/samples/maui-app) | `se.datatalks.sandbox.maui` | Typed on the screen |
| DT Capacitor | Capacitor 6, plain HTML | [sdks/capacitor/samples/plain](sdks/capacitor/samples/plain) | `se.datatalks.sandbox.capacitor` | `capacitor.config.json` |
| DT Ionic | Ionic 6 with React 18 on Capacitor 6, with the code of [the Ionic guide](sdks/capacitor/guide-ionic-react.md) | [sdks/capacitor/samples/ionic-react](sdks/capacitor/samples/ionic-react) | `se.datatalks.sandbox.ionic` | `DATATALKS_PUSH_APP_KEY` when `npx cap sync` runs |

Each has its own id, so they install side by side. On a simulator or an emulator they run as they are: they start, ask
for the permission and show what the SDK reports. A real push needs, for each id:

- an Android app in your Firebase project, and its `google-services.json` in the sample's Android folder (it stays out
  of git);
- an App ID with Push Notifications in your Apple developer account, for a device build;
- a push app in the Data Talks portal for that package and bundle id, whose app key (`dtpk_prd_…`) goes into the
  sample.

The icons, launch images and header marks come from [tools/sample-icons](tools/sample-icons): `render.ps1` renders and
copies them again after a change to the SVGs.

## Contributing and security

See [CONTRIBUTING.md](CONTRIBUTING.md). Report vulnerabilities as described in [SECURITY.md](SECURITY.md), not in a
public issue.

## License

[Apache License 2.0](LICENSE).
