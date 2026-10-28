# Install Sentinel

This is the whole install, in order. Each step ends with a check. Do them in
sequence: the later steps assume the earlier checks passed.

| Step | What | Where |
|---|---|---|
| 1 | Prerequisites | tailnet admin console |
| 2 | Install and start the hub | the always-on machine |
| 3 | Check the hub is on the tailnet | any tailnet device |
| 4 | Install the `sentinel` CLI | every machine that runs agents |
| 5 | Write the CLI config | same machines |
| 6 | Install the Mac and iPhone apps | your Mac and iPhone |
| 7 | Register the Claude Code hooks | every machine that runs Claude Code |

Steps 2 and 4 are one command on the hub's own Mac.

## 1. Prerequisites

- A Tailscale tailnet with MagicDNS and HTTPS certificates turned on (admin
  console, DNS page). The hub serves HTTPS with a certificate Tailscale issues for
  its node.
- Go 1.27 or newer on the machine that builds the binaries (`go version`).
- `jq`, for the hook installer (`brew install jq`).
- For iPhone pushes only: an Apple developer account, an APNs auth key (`.p8`),
  its key ID, your team ID, and the bundle ID you will give the apps (step 6).
  Without them everything works except pushes to the phone: escalations are logged
  instead.

Clone the repository on the machine that will host the hub:

```sh
git clone https://github.com/fdatoo/sentinel.git
cd sentinel
```

## 2. Install and start the hub

### macOS (launchd)

`deploy/install.sh` builds both binaries into `~/.local/bin` and installs the hub as
a launch agent that starts at login and restarts if it exits.

```sh
deploy/install.sh --owner you@example.com \
  --apns-key ~/Downloads/AuthKey_XXXXXXXXXX.p8 \
  --apns-key-id XXXXXXXXXX --apns-team-id YYYYYYYYYY \
  --apns-topic com.yourname.sentinel
```

`--apns-topic` is the bundle ID of the apps and must match it exactly. Leave out the
four `--apns-*` flags to skip pushes for now; re-running the script later with them
adds pushes. Re-running always rebuilds and restarts the agent.

`--owner` is the tailnet login allowed to register devices. Pass `--owner any` to
let every node on the tailnet register.

| Item | Location |
|---|---|
| Binaries | `~/.local/bin/sentinel-hub`, `~/.local/bin/sentinel` |
| State (database, node key, copied APNs key) | `~/Library/Application Support/sentinel-hub` |
| Log | `~/Library/Logs/sentinel-hub.log` |
| Launch agent | `~/Library/LaunchAgents/io.fdatoo.sentinel-hub.plist` |

Make sure `~/.local/bin` is on your `PATH`:

```sh
echo "$PATH" | tr ':' '\n' | grep -x "$HOME/.local/bin" || echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
```

On the first start the hub has no tailnet identity, so it logs a login URL. Open it
to add the node:

```sh
grep -m1 -i 'https://login.tailscale.com' ~/Library/Logs/sentinel-hub.log
```

To skip the browser step, start the hub once with an auth key instead
(Tailscale admin console, Settings, Keys). Stop the launch agent first, run the hub
in the foreground until it logs its URL, then stop it and let launchd take over:

```sh
launchctl bootout "gui/$(id -u)/io.fdatoo.sentinel-hub"
TS_AUTHKEY=tskey-auth-... ~/.local/bin/sentinel-hub --owner you@example.com   # ctrl-c once it logs its URL
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/io.fdatoo.sentinel-hub.plist
```

Later starts never need the key.

Check it worked:

```sh
launchctl print "gui/$(id -u)/io.fdatoo.sentinel-hub" | grep -E 'state|pid'
grep 'serving on the tailnet' ~/Library/Logs/sentinel-hub.log | tail -1
```

The second command prints the hub URL, for example
`https://sentinel.your-tailnet.ts.net`. Note it down: steps 3, 5 and 6 use it.

### Linux (systemd)

Build and install the binaries, then adapt the unit in `deploy/systemd/`.

```sh
(cd hub && go build -o bin/ ./cmd/sentinel-hub ./cmd/sentinel)
sudo install -m 755 hub/bin/sentinel-hub hub/bin/sentinel /usr/local/bin/
sudo install -d /etc/sentinel
sudo install -m 600 deploy/systemd/hub.env.example /etc/sentinel/hub.env
sudo install -m 600 AuthKey_XXXXXXXXXX.p8 /etc/sentinel/apns.p8
sudo install -m 644 deploy/systemd/sentinel-hub.service /etc/systemd/system/
```

Edit `/etc/sentinel/hub.env`: set `SENTINEL_HUB_FLAGS` to your owner, APNs IDs
and bundle ID, and uncomment `TS_AUTHKEY` for the first start. If you have no APNs key, remove
`--apns-key %d/apns.p8` and the `LoadCredential` line from the unit. Then:

```sh
sudo systemctl enable --now sentinel-hub
journalctl -u sentinel-hub -n 20 --no-pager
```

The journal shows `serving on the tailnet` and the hub URL. Remove `TS_AUTHKEY` from
`hub.env` afterwards; it is only needed once.

## 3. Check the hub is on the tailnet

From any other device on the tailnet (use your own hub URL):

```sh
curl -fsS https://sentinel.your-tailnet.ts.net/healthz
```

It prints `ok`. If it times out, the tailnet policy is the usual cause. The hub only
needs inbound TCP 443 from your devices. With a tag on the hub node:

```json
{
  "tagOwners": { "tag:sentinel": ["autogroup:admin"] },
  "grants": [
    { "src": ["autogroup:member"], "dst": ["tag:sentinel"], "ip": ["443"] }
  ]
}
```

Agents on tagged servers need their tag in `src` as well. Their requests are
attributed to the server's node and host name.

## 4. Install the CLI

On the hub's Mac, `deploy/install.sh` already put `sentinel` in `~/.local/bin`.

On every other machine that runs agents, build it from the repository and put it on
`PATH`:

```sh
(cd hub && go build -o bin/ ./cmd/sentinel)
install -m 755 hub/bin/sentinel ~/.local/bin/
```

Check it worked:

```sh
sentinel help
```

## 5. Configure the CLI

Point the CLI at the hub. The file is read by `sentinel` on every call, including
the Claude Code hooks.

```sh
mkdir -p ~/.config/sentinel
cat > ~/.config/sentinel/config.json <<'EOF'
{ "url": "https://sentinel.your-tailnet.ts.net" }
EOF
```

`SENTINEL_URL` in the environment overrides the file, and `XDG_CONFIG_HOME` moves it.

Check it worked, with a request nobody has to answer:

```sh
sentinel list
```

A table header with no rows (`ID STATE STAGE FROM TITLE OPTIONS`) means the CLI
reached the hub. `no hub configured` means the file or variable is missing, and a
connection error means step 3 failed from this machine.

A real round trip needs a registered device, which comes next.

## 6. Install the apps

The apps need macOS 15 and iOS 18. Both are built from `apple/`. The Xcode project
is generated from `apple/project.yml` and is checked in, so you only need
`xcodegen` if you change that file.

### Set your team and bundle ID

The project reads your developer team ID and the bundle ID both apps share from
`apple/Config/Local.xcconfig`, which git ignores. Copy the example and edit it:

```sh
cp apple/Config/Local.xcconfig.example apple/Config/Local.xcconfig
```

Set `DEVELOPMENT_TEAM` and `SENTINEL_BUNDLE_ID`. Without the file the apps build with
the placeholder bundle ID `com.example.sentinel` and no team, which is enough for
the simulator but not for a device. Pass the same bundle ID to the hub as
`--apns-topic` (step 2), or APNs rejects every push.

### Build and run from Xcode

1. Open `apple/Sentinel.xcodeproj`.
2. Choose the `SentinelMac` scheme, then Run. The app appears in the menu bar.
3. Choose the `SentinelPhone` scheme, pick your iPhone as the destination, then Run.

Debug builds register for sandbox pushes and release builds for production, so one
APNs key covers both.

### TestFlight

Both apps share one bundle ID, so one App Store Connect record covers iOS and
macOS. Create it once (New App, both platforms), then upload each archive. The
archive and upload steps, including the unsigned-archive workaround, are in
[testflight.md](testflight.md). Install from the TestFlight app on the iPhone and
from TestFlight on the Mac.

### Connect each app to the hub

In each app's settings, enter the hub URL from step 2. Saving registers the device
with the hub. Leave the dev node ID empty.

On the iPhone, allow notifications when asked. If you refuse, the phone still
registers and can answer from the app, but gets no pushes.

Check it worked:

```sh
sentinel devices
```

It lists the Mac and the iPhone. Then send yourself a test request:

```sh
sentinel ask --kind decision --title "Does this work?" \
  --option yes=Yes --option no=No --wait
```

The prompt appears on the Mac you are using. Answer it; the command prints the
resolved request as JSON and exits 0 for `yes`. To test escalation, run it again and
lock the Mac's screen: the request goes to the iPhone at once. If you leave an
unlocked Mac alone, it goes after the fallback time (three minutes for normal
urgency).

The Mac app lives in the menu bar and can launch at login. Approving an
authorization asks for Touch ID on the Mac and Face ID on the iPhone.

## 7. Register the Claude Code hooks

On each machine that runs Claude Code:

```sh
deploy/install-hooks.sh
```

This merges two hook commands into `~/.claude/settings.json`. It is safe to re-run:
it replaces any earlier Sentinel entries instead of adding duplicates, keeps every
other hook and setting, and saves the original as `settings.json.sentinel-backup` on
the first run. Preview with `--dry-run`, or remove the hooks with `--uninstall`.
[hooks.md](hooks.md) explains what each hook does and shows the JSON it writes.

Check it worked:

```sh
jq '.hooks | map_values(map(.hooks[].command))' ~/.claude/settings.json
```

You should see `sentinel hook` under `PermissionRequest` and `sentinel hook-done`
under `PostToolUse`, `PostToolUseFailure`, `UserPromptSubmit` and `Stop`. Start a
new Claude Code session and trigger a permission prompt: it also appears in
Sentinel, and answering in either place closes the other.

Optionally, install the agent skill so Claude Code knows when to ask for you on its
own:

```sh
mkdir -p ~/.claude/skills
ln -sfn "$PWD/skills/sentinel" ~/.claude/skills/sentinel
```

## Updating and removing

Update by pulling the repository and re-running `deploy/install.sh` with the same
flags; it rebuilds and restarts the agent. Rebuild the CLI on other machines the
same way as in step 4.

To remove everything on the hub's Mac:

```sh
launchctl bootout "gui/$(id -u)/io.fdatoo.sentinel-hub"
rm ~/Library/LaunchAgents/io.fdatoo.sentinel-hub.plist ~/.local/bin/sentinel-hub ~/.local/bin/sentinel
rm -r "$HOME/Library/Application Support/sentinel-hub"   # deletes the database and node key
deploy/install-hooks.sh --uninstall
```

## Troubleshooting

`--debug` makes the hub log every presence report a Mac sends. It is the quickest
way to see whether locking, sleep and idle time are noticed. Add it to the launch
agent's `ProgramArguments`.

| Symptom | Likely cause |
|---|---|
| `no hub configured` | step 5 not done on this machine |
| `curl` to `/healthz` hangs | tailnet policy blocks TCP 443, or the node is not logged in (step 2) |
| Device registration is refused | the login is not the `--owner` value |
| Phone never gets a push | no `--apns-*` flags, wrong `--apns-topic`, or notifications refused on the phone |
| Permission prompts never reach Sentinel | hooks not registered, or `sentinel` is not on the `PATH` Claude Code sees (use `deploy/install-hooks.sh --bin /full/path/sentinel`) |

Every timing is a hub flag: `--idle-threshold` (120s), `--heartbeat-timeout` (45s),
`--fallback-normal` (3m), `--fallback-high` (1m) and `--realert-high` (5m).

A registered device is trusted as a whole node, so an agent on the same machine as
a registered Mac or CLI could answer its own requests. Where that matters, run
agents on separate, tagged nodes, which cannot register devices when `--owner` is
set. See the Security section of [spec.md](spec.md).
