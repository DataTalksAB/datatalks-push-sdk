# Push events

Version 1.1.0 adds delivery, open and click events. The SDKs send them to `POST /v1/devices/{install_id}/events`, described
in [../openapi/push-v1.yaml](../openapi/push-v1.yaml) (`EventsRequest`, `EventsResponse`).

`POST /v1/server/events`, for a backend that reports events of devices without the SDK, is reserved for a later minor
version.

## What an event means

| Type | Sent when |
|---|---|
| `Delivery` | The SDK shows the push. Also implied by an open of a push with no delivery yet. |
| `Open` | The user taps the push. |
| `Click` | The same tap, when the push carries a link (`dt_link`). The event carries the link. |

## Repeats

A push counts at most one event of each type. The service answers `duplicate` for an event it already has, and keeps an
event's time between the moment the push was sent and 31 days later, never after the call. A retried call or a second
tap therefore changes nothing. When the service can't take the events, it answers 503 and the SDK sends the same events
again later.

## Privacy

Events carry no IP address, user agent, token or identity value.
