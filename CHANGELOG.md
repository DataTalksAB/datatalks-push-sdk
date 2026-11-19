# Changelog

All SDKs in this repository share one version.

## 1.0.0-rc.1

- One app key for every build: the portal issues `dtpk_{env}_…` keys, without `live_` or `test_`. Keys issued before
  keep working. Test pushes go to the phones added on the push app's Test devices tab, whatever key they were built
  with.

## 0.5.0-beta.1

First public release, for Android, iOS, .NET MAUI and Capacitor.

- Registration: the SDK registers the device with the app key and keeps the registration current (token changes,
  permission changes, a daily refresh).
- iOS through Firebase: an app whose iOS pushes go through its own Firebase project passes the FCM token with
  `setFcmToken` (`SetFcmToken` in MAUI), and the SDK registers it instead of the APNs token. The SDK still doesn't
  depend on Firebase.
- Identity: `identify` links the install to a signed-in user, optionally with an identity token signed by your backend;
  `logout` unlinks it. Repeating the same identity on the same UTC day doesn't call the service.
- Consent and deletion: the in-app marketing opt-in, and `deleteLocalData`, which also deletes the install on the
  service.
- Notifications: title, body, link, custom data, Android channel, colour and large icon, grouping and collapse keys.
  Pictures and delivery receipts on iOS come from a notification service extension (`DataTalksPushExtension`).
- Events: deliveries, opens and clicks, reported once each and retried until the service answers.
- Wrappers: .NET MAUI (`DataTalks.Push.Maui`) and Capacitor 6 to 8 (`@datatalks-ab/push-capacitor`) over the native SDKs.
- Sample apps for every SDK, and an Ionic React guide.
