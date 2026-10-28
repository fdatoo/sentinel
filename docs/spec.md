# Sentinel specification

Sentinel lets AI agents ask a person for something (a decision, an authorization,
or a real-world action) and wait for the answer. The question goes to whichever Mac
the person is using. If they are not at a Mac, or the Mac goes unanswered for a few
minutes, it goes to their iPhone, and through iOS notification mirroring to their
Apple Watch.

Decisions behind this spec:

- [ADR-0001](adr/0001-self-host-the-hub-in-go-on-the-tailnet.md): self-hosted Go hub on the tailnet
- [ADR-0002](adr/0002-route-by-presence-and-escalate-to-the-phone.md): presence-based routing with escalation
- [ADR-0003](adr/0003-gate-claude-code-permissions-with-a-permissionrequest-command-hook.md): Claude Code permission prompts through a `PermissionRequest` command hook
- [ADR-0004](adr/0004-build-native-clients-on-a-shared-swift-package.md): native Apple clients on a shared Swift package

## Components

```
 agents ──CLI / HTTP──▶ ┌───────────────┐ ◀──WebSocket── Mac app (each Mac)
 (Claude Code hook,     │      hub      │                 presence + prompts
  scripts, services)    │  Go, tsnet,   │
 agents ◀─long-poll,─── │  SQLite       │ ───APNs──────▶ iPhone app ──mirroring──▶ Watch
          SSE, webhook  └───────────────┘ ◀──HTTPS─────  answers over the tailnet
```

| Component | What it is |
|---|---|
| `sentinel-hub` | Go service, joins the tailnet as its own node through `tsnet`. Owns every request, its state machine and its timers. Runs on an always-on host. |
| `sentinel` | Go CLI. Creates requests, waits on them, and implements the Claude Code hook (`sentinel hook`). |
| Mac app | SwiftUI menu bar app, login item. Reports presence, shows prompts, sends answers. |
| iPhone app | SwiftUI app. Registers for APNs, shows actionable notifications and a request list. |
| `SentinelKit` | Swift package shared by both apps: models, API client, notification categories. |

Watch support in v1 is iOS notification mirroring only. There is no watchOS app.

## Request model

```
Request {
  id            string (ULID)
  agent         { host, label, session? }   // host from tsnet WhoIs, label self-declared
  kind          decision | authorize | action
  title         string                       // one line, shown in the notification
  body          markdown?                    // shown in the detail view
  options       [{ id, label, style: default | destructive }]
  allow_text    bool                         // free-text reply allowed
  urgency       low | normal | high
  sensitive     bool                         // notification shows only "<agent> needs you"
  grace_seconds int                          // delay before routing anywhere (default 0)
  expires_at    timestamp
  callback_url  string?                      // webhook on resolution
  state         pending | answered | expired | cancelled
  response?     { option_id?, text?, device, answered_at }
}
```

Kinds:

- `decision`: choose one option, or reply in free text when `allow_text` is set.
- `authorize`: approve or deny. Approving requires device authentication (see
  Security). Hook requests also offer "Always allow".
- `action`: the person does something in the real world, then answers `done` or
  `cant`, with an optional note.

The first answer wins. The hub applies it with a compare-and-set on `state`, and
any later answer gets `409` with the device that won.

## Hub API

All endpoints are served only on the tailnet. The hub identifies every caller with
`tsnet`'s `LocalClient.WhoIs`.

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/v1/requests` | Create a request. Returns it with `id`. |
| `GET` | `/v1/requests/{id}` | Fetch. `?wait=<seconds>` long-polls until the request resolves or the wait elapses. |
| `GET` | `/v1/requests/{id}/events` | SSE stream of state changes. |
| `DELETE` | `/v1/requests/{id}` | Cancel. Only the creating host may cancel. |
| `GET` | `/v1/requests?state=pending` | List, for the apps. |
| `POST` | `/v1/requests/{id}/response` | Answer. Only registered devices may answer. |
| `POST` | `/v1/devices` | Register a device: kind (mac, iphone), display name, APNs token. Keyed by tailnet node ID. |
| `GET` | `/v1/devices/ws` | Mac presence and delivery channel (WebSocket). |

When a request resolves, the hub POSTs it to `callback_url` if one is set. It
retries with backoff for up to an hour.

## Presence

Each Mac app holds a WebSocket to the hub. It sends a heartbeat every 15 seconds,
and sends one immediately whenever any of these change:

- `idle_seconds`, from `CGEventSource.secondsSinceLastEventType(.hidSystemState, ...)`.
  That counts only physical input, so a Mac you are screen-sharing into from
  another machine doesn't count as the one in use.
- screen locked or unlocked (`com.apple.screenIsLocked` / `com.apple.screenIsUnlocked`)
- display sleep, system sleep and wake, session switch (`NSWorkspace` notifications)

The hub considers a Mac active when it is unlocked and awake, its idle time is
under 120 seconds, and its last heartbeat arrived less than 45 seconds ago. If more
than one Mac is active, the one with the most recent input is the current Mac.

## Routing

The hub runs one state machine per request. Timer deadlines are stored in SQLite
and re-armed when the hub starts, so a restart doesn't lose an escalation.

1. Grace. Wait `grace_seconds`, 0 unless the caller asks for more. A request
   resolved or cancelled during grace never notifies anyone.
2. Mac. If a Mac is active, deliver to it and start the fallback timer: 3 minutes
   for `normal`, 1 minute for `high`. Escalate early if that Mac locks, sleeps,
   passes the idle threshold or disconnects. If a different Mac becomes current,
   move the prompt there and keep the original timer running. If no Mac is active,
   go straight to step 3.
3. Phone. Send an APNs alert to every registered iPhone. The prompt stays on the
   Mac. `low` urgency requests are sent as passive notifications.
4. Resolved. Retract the prompt everywhere else. On the Mac this goes over the
   socket. On the iPhone, a background push removes the delivered notification.
   iOS throttles background pushes, so delivery is best effort. The app also
   reconciles against `GET /v1/requests` whenever it opens, and answering an
   already-resolved request returns `409` with the device that won.
5. Expired or cancelled. Same retraction, and the agent gets the terminal state.

Default timings, to be tuned with use:

| Urgency | Mac fallback | Phone delivery | Phone re-alert |
|---|---|---|---|
| low | none (Mac only when active) | passive, once | none |
| normal | 3 min | time sensitive | none |
| high | 1 min | time sensitive | every 5 min until answered or expired |

## Clients

Both apps register their notification categories through `SentinelKit`, one per
kind and option layout. Pushes and local notifications use
`interruptionLevel = .timeSensitive` so they get through Focus.

The Mac app shows simple requests (two or three options) as actionable
notifications, with a text-input action when `allow_text` is set. Requests with a
long body or more options also open a floating `NSPanel`, since banners
auto-dismiss and are easy to miss. The menu bar icon shows the pending count. The
Mac app receives everything over its WebSocket and doesn't use APNs.

The iPhone app has actionable notifications, a detail view for long bodies, and
pending and history lists. Answering needs the tailnet. When the hub is
unreachable, the app says so instead of spinning. Turn on VPN On Demand in the
Tailscale app.

## CLI

```
sentinel ask --kind decision --title "Which migration strategy?" \
             --option a="Online" --option b="Offline" [--text] \
             [--urgency high] [--body-file plan.md] [--expires 2h] [--wait]
sentinel ask --kind action --title "Review PR #42" --wait \
             --until '<shell check>' [--every 2m]
sentinel wait <id> [--timeout 30m] [--until '<shell check>']
sentinel cancel <id>
sentinel hook                          # Claude Code PermissionRequest hook
sentinel hook-done                     # Claude Code PostToolUse, PostToolUseFailure,
                                       # UserPromptSubmit and Stop hook
```

`--wait` blocks and prints the resolved request as JSON on stdout. The exit code
encodes the outcome:

| Code | Meaning |
|---|---|
| 0 | answered: option chosen, done, or approved |
| 1 | answered: denied, or `cant` |
| 2 | expired |
| 3 | cancelled |
| 4 | hub unreachable or usage error |
| 5 | still pending when `--timeout` ran out |

`--until` is for waits that resolve outside Sentinel, like a PR review. While
waiting, the CLI runs the check through `/bin/sh` every `--every` (default 1
minute). When it exits 0, the CLI cancels the request, which retracts it from
every device, and exits 0. An answer in Sentinel still wins if it comes first.
The hub never runs the check, so it needs no forge credentials.

A Claude Code agent runs `sentinel ask ... --wait` as a background Bash command.
The harness wakes the agent when the command exits, so nothing polls and the agent
can keep working while it waits.

## Claude Code permission hook

`sentinel hook` is a `PermissionRequest` command hook, and `sentinel hook-done`
withdraws requests that were answered elsewhere. [hooks.md](hooks.md) is the current
reference, including how `AskUserQuestion` and `ExitPlanMode` are handled and
how to register the hooks. This section is the original design. These behaviors
were observed on Claude Code 2.1.310 with a test hook:

- The terminal prompt appears while the hook is still running. The two race.
- If the hook returns a decision first, the terminal prompt closes and the
  transcript shows "Allowed by PermissionRequest hook".
- If the terminal is answered first, the hook process receives `SIGTERM`. The
  desktop app did not send that signal when a prompt was answered there, which is
  why `sentinel hook-done` exists.

Flow:

1. Read the hook JSON from stdin: `tool_name`, `tool_input`, `cwd`, `session_id`,
   `permission_suggestions`.
2. Create an `authorize` request (`AskUserQuestion` and `ExitPlanMode` become
   `decision` requests instead, see hooks.md), routed immediately. Its title is built from
   the tool and its main argument (for example, `Bash: mkdir build`), and its
   options are Allow, Always allow and Deny, plus free text for a denial reason.
3. Long-poll until the request resolves.
4. Print the decision:
   - Allow: `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`
   - Always allow: the same, plus `updatedPermissions` echoing the first entry of
     `permission_suggestions`
   - Deny: `behavior: "deny"` with `message` set to the typed reply
5. On `SIGTERM`, `DELETE` the request and exit 0.
6. If the hub is unreachable, exit 0 with no output. The terminal prompt stays
   authoritative.

Configuration (user settings):

```json
{
  "hooks": {
    "PermissionRequest": [
      { "matcher": "*",
        "hooks": [{ "type": "command", "command": "sentinel hook", "timeout": 3600 }] }
    ]
  }
}
```

Limits:

- The default hook timeout is 600 seconds. When a hook times out in an interactive
  session, the terminal prompt remains. Whether `timeout` has an upper bound is
  untested.
- In headless sessions and background subagents, the docs say a missing hook
  decision means deny. For unattended agents, the hook is the only way to approve
  anything.
- A hook's allow doesn't override `deny` rules.
- Network requests from sandboxed commands don't fire `PermissionRequest`.
  Sentinel doesn't cover them in v1.

## Security

- Network: the hub listens only on its tailnet node. Tailnet ACLs decide which
  hosts can reach it.
- Identity: every call is attributed with `WhoIs` (node, user, tags). An agent's
  `label` is self-declared, but its `host` isn't.
- Who may answer: only devices registered through `/v1/devices`, keyed by tailnet
  node ID, and owned by the hub's tailnet user.
- Approval auth: an `authorize` approval needs local authentication. On iOS the
  approve action uses `.authenticationRequired`, and on the Mac the app asks for
  Touch ID through LocalAuthentication before sending. Denials need none.
- Grace period: a request in its grace stage can be denied but not approved
  (`409 too_early`). Nothing has been shown to the person yet, so an approval then
  can only come from software.
- Co-located agents: the hub trusts a registered device's node, not the process on
  it. An agent running on the same machine as a registered Mac or CLI can answer
  its own request through the API. Run agents that should not be able to do that on
  separate nodes, ideally tagged ones: with `--owner` set, tagged nodes can't
  register devices. Per-device signing, deferred below, is the real fix.
- Lock screen: with `sensitive` set, the notification shows only
  "<agent> needs you". The body appears after unlock, in the app.
- APNs: the hub holds the `.p8` signing key. APNs is the only traffic that leaves
  the tailnet.
- Callbacks: the hub POSTs resolved requests to whatever `callback_url` the caller
  supplied, from the hub's own tailnet identity. Treat every tailnet caller as able
  to make the hub send that POST.

Response signing with per-device Secure Enclave keys is deferred. It would matter
if the hub were a third-party cloud service. On a host you own, behind tailnet
identity, the cost isn't justified yet.

## Repository layout

```
hub/                     Go module
  cmd/sentinel-hub/      hub binary
  cmd/sentinel/          CLI binary
  internal/...           store, router, presence, apns, api
apple/
  SentinelKit/           Swift package
  Sentinel.xcodeproj     Mac and iPhone app targets
deploy/                  install.sh, install-hooks.sh, launchd and systemd units
skills/sentinel/         Claude Code skill for agents
docs/                    see docs/README.md
```
