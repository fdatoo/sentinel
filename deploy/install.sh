#!/bin/sh
# Installs the hub as a launch agent on this Mac, plus the CLI.
#
#   deploy/install.sh --owner you@example.com \
#     [--apns-key path/AuthKey_ID.p8 --apns-key-id ID --apns-team-id TEAM
#      --apns-topic BUNDLE_ID]
#
# Binaries go to ~/.local/bin, state to ~/Library/Application Support/sentinel-hub,
# and the log to ~/Library/Logs/sentinel-hub.log. Re-running rebuilds and restarts.
# On the first start the hub logs a login URL; open it to add the node to your tailnet.
set -eu

owner=""
apns_key=""
apns_key_id=""
apns_team=""
apns_topic=""
while [ $# -gt 0 ]; do
	case "$1" in
	--owner) owner="$2"; shift 2 ;;
	--apns-key) apns_key="$2"; shift 2 ;;
	--apns-key-id) apns_key_id="$2"; shift 2 ;;
	--apns-team-id) apns_team="$2"; shift 2 ;;
	--apns-topic) apns_topic="$2"; shift 2 ;;
	*) echo "unknown flag: $1" >&2; exit 2 ;;
	esac
done
[ -n "$owner" ] || { echo "--owner is required" >&2; exit 2; }

repo=$(cd "$(dirname "$0")/.." && pwd)
bin="$HOME/.local/bin"
state="$HOME/Library/Application Support/sentinel-hub"
log="$HOME/Library/Logs/sentinel-hub.log"
label=io.fdatoo.sentinel-hub
plist="$HOME/Library/LaunchAgents/$label.plist"

mkdir -p "$bin" "$state" "$HOME/Library/LaunchAgents"
chmod 700 "$state"
(cd "$repo/hub" && go build -o "$bin/" ./cmd/sentinel-hub ./cmd/sentinel)

apns_args=""
if [ -n "$apns_key" ]; then
	[ -n "$apns_key_id" ] && [ -n "$apns_team" ] && [ -n "$apns_topic" ] || { echo "--apns-key needs --apns-key-id, --apns-team-id and --apns-topic" >&2; exit 2; }
	install -m 600 "$apns_key" "$state/$(basename "$apns_key")"
	apns_args="<string>--apns-key</string><string>$state/$(basename "$apns_key")</string>
		<string>--apns-key-id</string><string>$apns_key_id</string>
		<string>--apns-team-id</string><string>$apns_team</string>
		<string>--apns-topic</string><string>$apns_topic</string>"
fi

cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$label</string>
	<key>ProgramArguments</key>
	<array>
		<string>$bin/sentinel-hub</string>
		<string>--owner</string><string>$owner</string>
		$apns_args
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>StandardErrorPath</key>
	<string>$log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$plist"
echo "installed; follow the log with: tail -f '$log'"
