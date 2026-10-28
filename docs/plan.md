# Milestone plan

Each milestone ends with something usable day to day. The order front-loads the
terminal-only path, so Sentinel is useful before any Apple code exists.

## M1: hub, CLI and Claude Code hook

- Go module with `sentinel-hub` and `sentinel` binaries.
- `tsnet` node, `WhoIs` attribution, SQLite store (requests, devices, timer deadlines).
- Request lifecycle: create, long-poll, SSE, cancel, answer with compare-and-set, expiry.
- `sentinel ask`, `wait`, `cancel`, and a temporary `sentinel answer <id> <option>`
  so requests can be answered before any app exists.
- `sentinel hook`, with fixtures captured from real `PermissionRequest` input and a
  test that `SIGTERM` cancels the request.
- Webhook callbacks with retry.

Done when: a Claude Code session's permission prompt can be approved with
`sentinel answer` from another machine on the tailnet, and answering in the
terminal first cancels the Sentinel request.

## M2: Mac app and presence routing

- `SentinelKit`: models, API client, notification categories.
- Menu bar app as a login item: device registration, WebSocket, presence reporting
  (idle, lock, sleep, session).
- Actionable notifications, `NSPanel` for long requests, pending count, Touch ID on approve.
- Hub: presence table, current-Mac selection, delivery over the socket, moving the
  prompt between Macs, and retraction.

Done when: requests appear on whichever Mac is in use and follow the user when they
switch.

## M3: iPhone app and escalation

- APNs from the hub (token-based `.p8` auth), device token registration.
- iPhone app: actionable notifications with `.authenticationRequired` on approve, a
  detail view, pending and history lists, and a "hub unreachable" state.
- Hub: fallback timers by urgency, early escalation when the Mac goes inactive,
  high-urgency re-alerts, and background-push retraction.
- Check that mirrored notifications on the Watch show the actions and can answer.

Done when: walking away from the Mac moves an unanswered request to the phone and
Watch within the configured time, and answering anywhere clears it everywhere.

## M4: hardening

- Restart safety: kill the hub mid-escalation, confirm the timers re-arm.
- Tune the presence threshold and fallback timings from a few weeks of real use.
- Package the hub as a launchd or systemd service, and document the tailnet ACLs.
- Re-check the hook race behavior against the current Claude Code version.

## Later

- watchOS app, for free-text and many-option requests.
- Response signing with per-device Secure Enclave keys, if the hub ever leaves the
  owner's hardware.
- An MCP server wrapper for agents that can't run background shell commands.
