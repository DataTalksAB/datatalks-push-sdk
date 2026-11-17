# Push API spec, version 1.1.0

The API between the Data Talks push SDKs (or a customer's backend) and the Data Talks push service, and the scenarios
both sides are tested against. The spec is released with the SDKs.

| Path | What |
|---|---|
| [openapi/push-v1.yaml](openapi/push-v1.yaml) | Routes, credentials, bodies, errors, limits and the SDK retry rules |
| [payload/payload-v1.md](payload/payload-v1.md) | The `dt_*` keys a push carries and the four delivery shapes |
| [payload/payload-v1.schema.json](payload/payload-v1.schema.json) | JSON Schema of the `dt_*` map |
| [payload/examples/](payload/examples/) | One FCM or APNs request per delivery shape |
| [fixtures/](fixtures/) | Request and response scenarios that the SDK tests replay |
| [events/](events/) | What the delivery, open and click events mean |

**Version 1.1.0** adds `POST /devices/{install_id}/events`, its fixtures `events-*.json` and the `pushes` fixture member.

## Versioning

- Adding an optional request field, a response field, a route, an error code or a skip reason is a minor version
  (`1.1.0`). Clients ignore fields and codes they don't know.
- Anything else (a removed or renamed field, a changed meaning, a new required field) is version 2, served under `/v2`
  next to `/v1`.
- Every change updates the fixtures in the same commit.

## Fixtures

Each file in `fixtures/` is one scenario: an app set-up and the requests a client sends, in order, with the answer the
service gives.

```json
{
  "name": "register-android-refresh",
  "summary": "…",
  "app": { "status": "Ready", "require_verified_identity": true, "platforms": { "android": { "transport": "fcm" } } },
  "identity_tokens": { "member_1001": { "sub": "member-1001", "email": "anna@example.com", "expires_in_seconds": 300 } },
  "harness": { "limits": { "per_install_per_minute": 2 } },
  "steps": [ { "request": { "method", "path", "headers", "body" }, "response": { "status", "headers", "body" } } ]
}
```

- **`app`**: the push app of the scenario: its status, whether it requires verified identity, and its platforms with
  their transport. Every scenario starts with no devices.
- **`identity_tokens`** (optional): tokens signed with the app's identity secret (`aud` = the app id). A negative
  `expires_in_seconds` makes an expired token.
- **`harness`** (optional): settings that only keep a scenario short, such as a lower rate limit.
- **`pushes`** (optional, version 1.1.0): pushes sent before the steps, by name: the `install_id` each went to, `sent_at`,
  and the flags already set (`delivery`, `open`, `click`, all false by default). A request names one by `{{uid:NAME}}`.
  The scenario's clock reads `2026-11-04T12:00:30Z`.
- **`steps`**: run in order. The SDK tests answer them from a mock server.

**Placeholders** (strings in double braces):

| Placeholder | In a request | In a response |
|---|---|---|
| `{{app_key}}` | The app's live key | — |
| `{{app_key:test}}`, `{{app_key:revoked}}`, `{{app_key:other_environment}}` | A test key, a revoked key, a key of the other environment | — |
| `{{server_key}}` | The app's server key | — |
| `{{capture:device_secret}}` | — | Any 32 base62 characters; remembered as `device_secret` |
| `{{device_secret}}` | The remembered secret | — |
| `{{wrong_device_secret}}` | A well-formed secret that isn't the device's | — |
| `{{token:NAME}}` | The token signed from `identity_tokens.NAME` | — |
| `{{uid:NAME}}` | The `dt_uid` of `pushes.NAME` | — |
| `{{uuid}}` | — | Any lower-case UUID |
| `{{any}}` | — | Any value (used for `message` and `Retry-After`) |

**Matching.** The SDK tests check the method, path and headers the SDK sends, check its body against the OpenAPI schema
(device metadata comes from the test device, so it can differ from the fixture), and serve the response with sample
values for the placeholders: `device_secret` `Fixture0Secret000000000000000000`, `{{uuid}}`
`00000000-0000-5000-8000-000000000000`, `{{any}}` `"fixture"` or `1` for `Retry-After`. The service's own tests replay
the same scenarios and compare the status code, the listed headers and the body exactly.

Values in fixtures are fake: tokens contain `FIXTURE` or are made-up hex, and keys and secrets appear only as
placeholders.
