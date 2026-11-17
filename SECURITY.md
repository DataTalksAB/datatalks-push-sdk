# Security

Please don't report a vulnerability in a public issue. Write to [security@datatalks.se](mailto:security@datatalks.se) with
what you found and how to reproduce it.

## What the SDK does with secrets

- The app key is publishable: it ships inside the app, and it can only reach the device routes. A server key (`dtsk_...`) never belongs in an app.
- The device secret, the install id, the FCM value and a waiting identity are stored encrypted with a key in the Android Keystore or the iOS Keychain.
- Keys, secrets, tokens and identity values never go into a URL or a log line.
