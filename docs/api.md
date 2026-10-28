# Wire contract

This is the exact JSON the hub, the CLI and the Swift clients exchange. The
[spec](spec.md) explains the behavior; this file pins the shapes. Field names are
`snake_case`. Timestamps are RFC 3339 strings in UTC. Unknown fields must be
ignored by every reader.

## Base URL and identity

In production the hub serves HTTPS on its tailnet node with `tsnet`'s
`ListenTLS`, for example `https://sentinel.example-tailnet.ts.net`. Callers are
identified by their tailnet node, which carries no headers.

In dev mode (`sentinel-hub --dev`) the hub serves plain HTTP on `127.0.0.1:7878`.
There the caller's identity comes from the `X-Sentinel-Node` header (a stable node
ID) and `X-Sentinel-Host` (a display hostname), defaulting to `dev-node` and
`localhost`. Dev mode exists for tests and the simulator, and is never exposed on
the tailnet.

Every request with a body must send `Content-Type: application/json`, or the
hub answers `415`. A browser can only send that header cross-origin after a CORS
preflight, which the hub never grants, so a web page open on a registered device
can't forge an answer.

## Errors

Every non-2xx response has this body:

```json
{ "error": { "code": "already_resolved", "message": "answered on Sam's iPhone" } }
```

| HTTP | `code` | When |
|---|---|---|
| 400 | `invalid_request` | malformed body or failed validation |
| 403 | `forbidden` | caller isn't allowed (unregistered device answering, non-creator cancelling) |
| 404 | `not_found` | unknown request or device |
| 409 | `already_resolved` | answering or cancelling a request that isn't pending; `message` names the outcome |
| 409 | `too_early` | a positive answer to a request still in its grace stage (denials are accepted) |
| 415 | `invalid_request` | a POST body that isn't `application/json` |
| 429 | `too_many_pending` | 500 requests are already pending |

## Request object

```json
{
  "id": "01JBV5Q8ZK6V0M7W3T2N4R8C1D",
  "agent": { "host": "studio", "node": "nodeid:abc", "label": "claude-code", "session": "5f1c..." },
  "kind": "authorize",
  "title": "Bash: rm -rf node_modules",
  "body": "Working directory `/Users/sam/app`",
  "options": [
    { "id": "allow",  "label": "Allow",        "style": "default",     "negative": false },
    { "id": "always", "label": "Always allow", "style": "default",     "negative": false },
    { "id": "deny",   "label": "Deny",         "style": "destructive", "negative": true }
  ],
  "allow_text": true,
  "urgency": "normal",
  "sensitive": false,
  "grace_seconds": 0,
  "created_at": "2026-10-24T09:00:00Z",
  "expires_at": "2026-10-25T09:00:00Z",
  "callback_url": null,
  "state": "pending",
  "stage": "mac",
  "routed_to": "01JBV5...device-id",
  "response": null,
  "resolved_at": null
}
```

| Field | Values |
|---|---|
| `kind` | `decision`, `authorize`, `action` |
| `urgency` | `low`, `normal`, `high` |
| `state` | `pending`, `answered`, `expired`, `cancelled` |
| `stage` | `grace`, `mac`, `phone`, `done` (routing progress, informational) |
| `option.style` | `default`, `destructive` |
| `option.negative` | `true` marks a deny or can't outcome (CLI exit code 1). In an `authorize` request, choosing a non-negative option requires device authentication. |

`response`, once answered:

```json
{ "option_id": "deny", "text": "use npm ci instead", "device_id": "01JBV...", "device_name": "Sam's iPhone", "answered_at": "2026-10-24T09:01:12Z" }
```

`option_id` may be null when `allow_text` is set and only text was given.

## Creating a request

`POST /v1/requests`

```json
{
  "kind": "decision",
  "title": "Which migration strategy?",
  "body": "optional markdown",
  "options": [ { "id": "online", "label": "Online" }, { "id": "offline", "label": "Offline" } ],
  "allow_text": false,
  "urgency": "normal",
  "sensitive": false,
  "grace_seconds": 0,
  "expires_in_seconds": 86400,
  "callback_url": null,
  "agent": { "label": "claude-code", "session": "5f1c..." }
}
```

The response is `201` with the full request object. The hub fills
`agent.host` and `agent.node` from the caller's identity.

Validation and defaults:

- `title` is required, at most 200 characters. `body` is at most 64 KiB.
- `options`: at most 8. Ids are unique, non-empty, at most 64 characters. `style`
  defaults to `default` and `negative` to `false`.
- If `options` is empty, the hub supplies defaults:
  - `authorize`: `approve` ("Approve") and `deny` ("Deny", destructive, negative)
  - `action`: `done` ("Done") and `cant` ("Can't", negative)
  - `decision` with no options requires `allow_text: true`
- `urgency` defaults to `normal`. `grace_seconds` ranges over 0 to 300, default 0.
- `expires_in_seconds` ranges over 60 to 604800, default 86400.

## Reading and waiting

- `GET /v1/requests/{id}` returns the request object.
- `GET /v1/requests/{id}?wait=60` holds the response until the request leaves
  `pending` or `wait` seconds pass (max 300), then returns the request object
  either way. The client loops.
- `GET /v1/requests/{id}/events` is an SSE stream. Each event is
  `event: request` with the full request object as `data`. It sends the current
  state on connect, and closes after the request resolves.
- `GET /v1/requests?state=pending&limit=50` returns `{ "requests": [ ... ] }`,
  newest first. `state` may be omitted for all states.

## Cancelling

`DELETE /v1/requests/{id}`. Only the node that created the request may cancel it.
Returns `200` with the request object (`state: cancelled`), or `409` if it had
already resolved.

## Answering

`POST /v1/requests/{id}/response`

```json
{ "option_id": "approve", "text": null }
```

The caller must be a registered device. At least one of `option_id` or `text`
must be set, `option_id` must name an option, and `text` requires `allow_text`.
Returns `200` with the resolved request object, or `409` if another answer won.

Authentication for `authorize` approvals is the client's job (Face ID or Touch ID
before sending). The hub doesn't verify it in v1.

## Devices

`POST /v1/devices` registers or updates the caller's node:

```json
{ "kind": "iphone", "name": "Sam's iPhone", "apns_token": "a1b2...hex", "apns_environment": "sandbox" }
```

`kind` is `mac`, `iphone` or `cli`. A `cli` device can answer but never
receives deliveries; `sentinel register` creates one so a terminal can answer
with `sentinel answer`. `apns_token` and `apns_environment` (`sandbox` or
`production`) are for iPhones only. An iPhone registered without a token
can answer but gets no pushes; the app does this when notification permission
is refused. The response is `200` with:

```json
{ "id": "01JBV...", "kind": "iphone", "name": "Sam's iPhone", "node": "nodeid:xyz", "created_at": "2026-10-23T18:00:00Z", "last_seen_at": "2026-10-23T18:05:00Z" }
```

Registration is idempotent per node. `GET /v1/devices` lists the devices as
`{ "devices": [ ... ] }`.

## Mac channel

`GET /v1/devices/ws` upgrades to a WebSocket. The caller must already be
registered as a `mac`. All frames are JSON text.

Mac to hub:

```json
{ "type": "presence", "idle_seconds": 12.5, "locked": false, "asleep": false, "display_asleep": false, "session_active": true }
```

The Mac sends this every 15 seconds and immediately on any change. When the
system is about to sleep, it sends `asleep: true` before the socket drops.

Hub to Mac:

```json
{ "type": "sync",    "requests": [ { ...request... } ] }
{ "type": "deliver", "request": { ...request... } }
{ "type": "retract", "request": { ...request... } }
```

- `sync` arrives on connect, carrying every pending request currently routed to
  this Mac, or already escalated past it: the newest 50 at most, and no more than
  768 KiB in all. Older ones stay answerable from the iPhone.
- `deliver` means show this request now.
- `retract` means stop showing it. The embedded request carries the terminal
  state and the `response`, so the Mac can say who answered.

Answers go over `POST /v1/requests/{id}/response`, not the socket.

## APNs payloads

Alert push, sent at escalation:

```json
{
  "aps": {
    "alert": { "title": "claude-code on studio", "body": "Bash: rm -rf node_modules" },
    "sound": "default",
    "category": "sentinel.authorize.hook",
    "interruption-level": "time-sensitive",
    "thread-id": "sentinel",
    "mutable-content": 1
  },
  "request_id": "01JBV5Q8ZK6V0M7W3T2N4R8C1D"
}
```

The headers are `apns-push-type: alert`, `apns-collapse-id: <request id>`, and
`apns-priority: 10`. For a `sensitive` request, `alert.body` is `"needs you"` and
the title is just the agent label. `low` urgency uses `"interruption-level": "passive"`
and no sound.

Retract push, sent when a request resolves:

```json
{ "aps": { "content-available": 1 }, "retract": "01JBV5Q8ZK6V0M7W3T2N4R8C1D" }
```

The headers are `apns-push-type: background` and `apns-priority: 5`.

## Notification categories

Notification action titles are fixed when an app registers its categories, so a
category only fits a request whose option labels match it exactly. The hub
chooses the category. It uses a row below when the request's kind, `allow_text`
and option ids and labels (in order) all match that row exactly, and
`sentinel.open` otherwise. Both apps register every row up front.

| Category | Request shape | Actions (identifier: title) |
|---|---|---|
| `sentinel.authorize.2` | authorize, options `approve`/`deny`, no text | `approve`: Approve (auth required), `deny`: Deny (destructive) |
| `sentinel.authorize.hook` | authorize, options `allow`/`always`/`deny`, text allowed | `allow`: Allow (auth required), `always`: Always allow (auth required), `deny`: Deny (destructive) |
| `sentinel.action.2` | action, options `done`/`cant`, no text | `done`: Done, `cant`: Can't |
| `sentinel.open` | everything else, and every sensitive request | none (tapping opens the app) |

An action identifier is the option id it answers with. For the hook layout, a
denial reason needs the app, since three buttons are the most a notification
reliably shows. Every `decision` request uses `sentinel.open`.

On the Mac, the panel shows every request with its real labels, and the
notification is a pointer to the panel that also carries these actions when the
category matches.
