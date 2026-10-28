# Sentinel

Sentinel lets AI agents ask you for a decision, an authorization or a real-world
action, and wait for the answer. A request goes to the Mac you are using. If you
are away from your Macs, or you do not answer in a few minutes, it goes to your
iPhone, and from there to your Apple Watch through notification mirroring.

It is self-hosted: a Go hub on your tailnet, a small `sentinel` CLI for agents,
and native Mac and iPhone apps for you. The only traffic that leaves the tailnet is
the APNs push.

```
 agents ──CLI / HTTP──▶ ┌───────────────┐ ◀──WebSocket── Mac app (each Mac)
 (Claude Code hooks,    │      hub      │                 presence + prompts
  scripts, services)    │  Go, tsnet,   │
 agents ◀─long-poll,─── │  SQLite       │ ───APNs──────▶ iPhone app ──mirroring──▶ Watch
          SSE, webhook  └───────────────┘ ◀──HTTPS─────  answers over the tailnet
```

## How a request is routed

1. The Mac apps report presence: locked or unlocked, asleep, and idle time. A Mac
   is active when it is unlocked and awake, with input in the last 2 minutes.
2. If a Mac is active, the prompt appears there. If you switch Macs, it follows you.
3. If no Mac is active, or the active Mac does not answer within 3 minutes (1 minute
   for high urgency), the hub sends an APNs push to your iPhone. The prompt stays
   on the Mac.
4. The first answer wins. The prompt is withdrawn everywhere else, and the agent
   gets the result. Approving an authorization needs Touch ID on the Mac or Face ID
   on the iPhone.

Details are in [docs/spec.md](docs/spec.md) and
[ADR-0002](docs/adr/0002-route-by-presence-and-escalate-to-the-phone.md).

## What agents can ask

| Kind | You | Example |
|---|---|---|
| `decision` | pick an option, or type a reply | "Which migration strategy?" |
| `authorize` | approve or deny | "Run the prod migration?" |
| `action` | do something, then tap Done or Can't | "Plug in the YubiKey" |

```sh
sentinel ask --kind decision --title "Which approach?" \
  --option a="Rewrite" --option b="Patch" --wait
```

`--wait` blocks and prints the answer as JSON. The exit code says what happened
(0 positive, 1 denied, 2 expired, 3 cancelled, 4 error, 5 timeout). See
[docs/cli.md](docs/cli.md).

## Claude Code integration

Two hook commands put Claude Code's own prompts in Sentinel:

- `sentinel hook` on `PermissionRequest`. Tool permissions arrive as Allow, Always
  allow and Deny. `AskUserQuestion` and `ExitPlanMode` arrive as decision requests.
  Answering in the terminal or in Sentinel closes the other.
- `sentinel hook-done` on `PostToolUse`, `PostToolUseFailure`, `UserPromptSubmit`
  and `Stop`. It withdraws requests that were answered outside Sentinel.

`deploy/install-hooks.sh` registers both in `~/.claude/settings.json` without
duplicating them. See [docs/hooks.md](docs/hooks.md).

## Quickstart

You need a tailnet with MagicDNS and HTTPS on, Go 1.27+ and `jq`. On the Mac that
will host the hub:

```sh
git clone https://github.com/fdatoo/sentinel.git && cd sentinel
deploy/install.sh --owner you@example.com          # builds, installs, starts the hub
grep 'serving on the tailnet' ~/Library/Logs/sentinel-hub.log   # prints the hub URL
mkdir -p ~/.config/sentinel
echo '{ "url": "https://sentinel.your-tailnet.ts.net" }' > ~/.config/sentinel/config.json
deploy/install-hooks.sh                            # registers the Claude Code hooks
```

Then build `SentinelMac` and `SentinelPhone` from `apple/Sentinel.xcodeproj` (or
install them from TestFlight), enter the hub URL in each app's settings, and
check with `sentinel devices`. On the first start the hub logs a Tailscale login URL
to approve, and pushes to the iPhone need an APNs key. Both are covered, with a
check after every step, in [docs/install.md](docs/install.md).

## Repository

| Path | Contents |
|---|---|
| `hub/` | Go module: `sentinel-hub` and `sentinel` |
| `apple/` | Mac and iPhone apps, and the shared `SentinelKit` Swift package |
| `deploy/` | install scripts, launchd and systemd units |
| `skills/sentinel/` | Claude Code skill that teaches agents when to ask |
| `docs/` | [documentation index](docs/README.md) |

## Security and license

Sentinel trusts your tailnet; read [SECURITY.md](SECURITY.md) for what that means
and how to report a problem. It is released under the [MIT license](LICENSE).
