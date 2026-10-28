#!/bin/sh
# Registers the Sentinel hooks in a Claude Code settings file. Safe to re-run:
# it removes any earlier Sentinel entries before adding the current ones, and
# leaves every other hook and setting alone.
#
#   deploy/install-hooks.sh [--settings FILE] [--bin PATH] [--dry-run] [--uninstall]
#
#   --settings FILE  settings file to edit (default ~/.claude/settings.json)
#   --bin PATH       how the hooks invoke the CLI (default: sentinel, found on PATH)
#   --dry-run        print the resulting JSON and change nothing
#   --uninstall      remove the Sentinel hooks instead of adding them
#
# Registered hooks:
#   PermissionRequest                                       sentinel hook       (timeout 3600)
#   PostToolUse, PostToolUseFailure, UserPromptSubmit, Stop sentinel hook-done  (timeout 30)
#
# The first run saves the old file next to it as settings.json.sentinel-backup.
set -eu

settings="$HOME/.claude/settings.json"
bin="sentinel"
dry=0
remove=0
while [ $# -gt 0 ]; do
	case "$1" in
	--settings) settings="$2"; shift 2 ;;
	--bin) bin="$2"; shift 2 ;;
	--dry-run) dry=1; shift ;;
	--uninstall) remove=1; shift ;;
	-h | --help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) echo "unknown flag: $1" >&2; exit 2 ;;
	esac
done

command -v jq >/dev/null || { echo "jq is required (brew install jq)" >&2; exit 1; }

if [ -f "$settings" ]; then
	current=$(cat "$settings")
	[ -n "$current" ] || current='{}'
else
	current='{}'
fi
printf '%s' "$current" | jq -e 'type == "object"' >/dev/null ||
	{ echo "$settings is not a JSON object; fix it first" >&2; exit 1; }

# strip drops every earlier Sentinel hook (any path to the CLI), then drops
# matcher groups and events left empty.
updated=$(printf '%s' "$current" | jq --arg bin "$bin" --argjson remove "$remove" '
  def ours: .command? // "" | test("(^|/)sentinel hook(-done)?$");
  def strip:
    map(.hooks |= map(select(ours | not)) | select(.hooks | length > 0));
  def add(event; group):
    .hooks[event] = ((.hooks[event] // []) | strip) + (if $remove == 1 then [] else [group] end);
  (.hooks //= {})
  | add("PermissionRequest"; {matcher: "*", hooks: [{type: "command", command: ($bin + " hook"), timeout: 3600}]})
  | add("PostToolUse"; {matcher: "*", hooks: [{type: "command", command: ($bin + " hook-done"), timeout: 30}]})
  | add("PostToolUseFailure"; {matcher: "*", hooks: [{type: "command", command: ($bin + " hook-done"), timeout: 30}]})
  | add("UserPromptSubmit"; {hooks: [{type: "command", command: ($bin + " hook-done"), timeout: 30}]})
  | add("Stop"; {hooks: [{type: "command", command: ($bin + " hook-done"), timeout: 30}]})
  | .hooks |= with_entries(select(.value | length > 0))
  | if .hooks == {} then del(.hooks) else . end
')

if [ "$dry" = 1 ]; then
	printf '%s\n' "$updated"
	exit 0
fi

if [ "$updated" = "$(printf '%s' "$current" | jq .)" ]; then
	echo "$settings already up to date"
	exit 0
fi

mkdir -p "$(dirname "$settings")"
if [ -f "$settings" ] && [ ! -f "$settings.sentinel-backup" ]; then
	cp -p "$settings" "$settings.sentinel-backup"
fi
tmp=$(mktemp "$settings.XXXXXX")
printf '%s\n' "$updated" >"$tmp"
mv "$tmp" "$settings"
if [ "$remove" = 1 ]; then
	echo "removed Sentinel hooks from $settings"
else
	echo "registered Sentinel hooks in $settings"
	command -v "$bin" >/dev/null 2>&1 || echo "warning: '$bin' is not on PATH; Claude Code will not find it (use --bin /full/path/sentinel)" >&2
fi
