# Contributing

## The spec

`spec/` is what the SDKs and the service agree on. Read its [README](spec/README.md) first: a change there is versioned,
and it updates the fixtures in the same commit. Fixture values are fake, so no real token, key or secret goes into this
repository.

## Android

You need JDK 17 and the Android SDK with platform 36.

```bash
cd sdks/android
./gradlew :push:testDebugUnitTest :push:lintDebug :samples:compose:assembleDebug
```

## iOS

You need Xcode. From the repository's root:

```bash
xcodebuild test -scheme DataTalksPush-Package -destination "platform=iOS Simulator,name=iPhone 17"
```

## .NET MAUI

You need .NET 10 with the MAUI workloads, and a Mac for the iOS side. See [sdks/maui/README.md](sdks/maui/README.md).

## Capacitor

You need Node.js 18 or later, Capacitor 6's minimum. See [sdks/capacitor/README.md](sdks/capacitor/README.md).

## Releases

All SDKs share one version, and one tag (the plain version, for example `0.5.0-beta.1`) publishes them all. See
[RELEASING.md](RELEASING.md).

## All SDKs

- Keep the dependencies few. The SDK lives inside other people's apps, so a new library is a possible version clash for
  them. The iOS SDK has none.
- Nothing the SDK does may crash the app or block its main thread.
- Keys, secrets, tokens and identity values never go into a URL or a log line.
