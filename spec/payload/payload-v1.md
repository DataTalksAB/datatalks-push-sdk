# Push payload, version 1

What a Data Talks push carries to the device, and how the SDKs read it. Data Talks builds it when it sends a push; the
SDKs render it and route opens. [payload-v1.schema.json](payload-v1.schema.json)
is the machine-readable form of the `dt_*` map; [examples/](examples/) has one message per delivery shape.

## The `dt_*` keys

Every value is a string, because FCM data values must be strings. iOS carries the same keys at the top level of the
APNs payload, next to `aps`.

| Key | Required | Value | Used by |
|---|---|---|---|
| `dt_v` | yes | `"1"`, the payload version | Both SDKs: a message with `dt_v` is ours (`handleRemoteMessage` returns true) |
| `dt_uid` | yes | The message's unique id (`unique_id`), 1–64 characters | Delivery, open and click events (contract 1.1.0) |
| `dt_title` | one of title and body | The title | Android rendering |
| `dt_body` | one of title and body | The body | Android rendering |
| `dt_image` | no | An `https` URL of a JPEG or PNG | Android big picture; iOS needs the notification service extension |
| `dt_link` | no | An `https` URL or an app link (`scheme://…`) opened on tap | Both SDKs; without it a tap opens the app |
| `dt_data` | no | A JSON object as a string, at most 1 KB | Handed to the app's `onNotificationOpened` and message callbacks |
| `dt_channel` | no | The Android notification channel id | Android; default `datatalks_default` |
| `dt_sound` | no | `default` or a sound resource name | Reserved: not set yet |
| `dt_badge` | no | A non-negative integer | Reserved (iOS) |
| `dt_collapse` | no | A group key: a newer push with the same key replaces the older one | Android notification tag; iOS uses the `apns-collapse-id` header |
| `dt_thread` | no | Groups notifications in the iOS notification centre | iOS (`aps.thread-id` carries the same value) |
| `dt_color` | no | The accent colour, `#RRGGBB` | Android: tints the small icon and the app name, in place of the manifest's colour |
| `dt_large_icon` | no | An `https` URL of a square PNG or JPEG, ideally 256 × 256 px | Android: the large icon, shown at the right of the notification |

Unknown `dt_*` keys are ignored, so a minor version can add keys. A change to the meaning of a key is version `2`.

`dt_color` and `dt_large_icon` are the push app's notification look (set on the push app in the Data Talks portal). Only Android
payloads carry them: iOS always shows the app's icon. The small icon can't come with a push, because Android draws it
from a drawable in the app, so it stays the manifest's.

## Delivery shapes

The device row's `source` decides the shape (§2.6):

1. **Android, `source = sdk`:** a data-only FCM message with `android.priority = HIGH` and only the `dt_*` keys. The SDK
   renders it with `NotificationCompat` (small icon, colour and default channel name from the app's manifest metadata,
   the colour from `dt_color` when there is one) and must always show a notification for it: Firebase lowers the
   priority of apps whose high-priority messages show nothing.
2. **Android, `source = server` or `csv`:** the same keys **plus** an FCM `notification` block (title, body, image),
   because the app may have no Data Talks SDK, and `android.notification.color` from `dt_color`. In the background
   Android shows the `notification` block, without the large icon, which FCM has no field for. In the foreground an app
   with the SDK gets it in `onMessageReceived`, and the SDK shows it like shape 1.
3. **iOS through APNs:** `aps.alert` (title, body), `aps.mutable-content = 1` (lets the notification service extension add the image
   and a delivery receipt), `aps.thread-id` from `dt_thread`, plus the `dt_*` keys at the top level. Headers:
   `apns-push-type: alert`, `apns-priority: 10`, `apns-expiration` from the campaign's time to live, `apns-collapse-id`
   from `dt_collapse`.
4. **iOS through FCM** (apps whose iOS app already uses Firebase): an FCM message whose `apns` block holds shape 3's
   `aps` and headers, with the `dt_*` keys in `data`.

## Size

FCM and APNs both refuse payloads over 4 KB. The sender truncates the body, then drops `dt_data`, then fails the message
as `RenderingFailure`. `dt_data` is limited to 1 KB on its own, so the composer refuses bigger data before
sending.

## Opens

A tap opens `dt_link` (an `https` link through the system browser or the app's verified app links, any other scheme
through the app), or the app's launcher activity / scene. The SDK then calls `onNotificationOpened(deepLink, data)`
with `dt_link` and the parsed `dt_data`. An app that routes links itself turns opening off (`openLinks`); a tap then
opens the app, and `dt_link` reaches `onNotificationOpened` only.

From contract 1.1.0 the SDK reports, with the push's `dt_uid` ([../events/README.md](../events/README.md)):
- a delivery when it shows the push;
- an open on a tap;
- a click on the same tap when the push has a `dt_link`, whether the SDK opens the link or the app routes it.
