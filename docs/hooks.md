# Claude Code hooks

Sentinel plugs into Claude Code with two commands, both subcommands of the
`sentinel` CLI. Install them with `deploy/install-hooks.sh` (see
[install.md](install.md), step 7). This page says what they do and what ends up in
`~/.claude/settings.json`.

## The two commands

| Command | Claude Code events | Timeout | Purpose |
|---|---|---|---|
| `sentinel hook` | `PermissionRequest` | 3600 s | Turns a prompt into a Sentinel request and prints Claude Code's decision. |
| `sentinel hook-done` | `PostToolUse`, `PostToolUseFailure`, `UserPromptSubmit`, `Stop` | 30 s | Withdraws requests that were answered somewhere other than Sentinel. |

The `PermissionRequest` timeout is how long a prompt can wait for you. Claude Code's
default is 600 seconds; the hook asks for the same 3600 seconds a Sentinel request
lives.

## What each prompt becomes

`sentinel hook` reads the hook payload on stdin and tells prompts apart by
`tool_name`:

| Prompt | Sentinel request | Options |
|---|---|---|
| `AskUserQuestion` | one `decision` request per question | the question's own options; a typed reply is the "Other" answer |
| `ExitPlanMode` | one `decision` request holding the plan | Approve, Keep planning (a typed reply becomes the denial message) |
| Any other tool | one `authorize` request titled like `Bash: mkdir build` | Allow, Always allow, Deny; free text on a denial is sent back as the reason |

Details:

- Always allow appears only when Claude Code offered `permission_suggestions`; the
  hook returns the first one as `updatedPermissions`.
- Answering `AskUserQuestion` allows the call with the original input plus an
  `answers` map, so Claude Code sees the answers as if you had typed them.
  Multi-select questions take one pick or a comma-separated typed reply.
- If any request of a call is left unanswered or expires, the hook prints nothing
  and the terminal prompt stays in charge.
- If the hub is unreachable, the hook exits silently and the terminal prompt works
  as usual. Headless sessions and background subagents have no terminal prompt, so
  there a missing decision means deny.
- A hook's allow does not override `deny` rules in your Claude Code settings.
- Network requests from sandboxed commands do not fire `PermissionRequest`, so
  Sentinel cannot approve them.

The terminal prompt and Sentinel race: whichever answers first wins and the other
is closed.

## Withdrawal

When you answer in the terminal first, the hook should be told to stop. It
withdraws its requests when it receives `SIGTERM`, `SIGINT` or `SIGHUP`, or when its
parent process changes because the session died. Claude Code's desktop app does not
always signal the hook, so `sentinel hook-done` backs it up:

- After a tool call finishes (`PostToolUse`, `PostToolUseFailure`) it cancels that
  session's pending requests whose titles match the call.
- After a new prompt or the end of a turn (`UserPromptSubmit`, `Stop`) it cancels
  all of the session's pending requests.

So a prompt you deny in the terminal disappears from your devices at the next
prompt or the end of the turn, not immediately. `hook-done` always exits 0 and does
nothing if the hub is unreachable.

## What the installer writes

```json
{
  "hooks": {
    "PermissionRequest": [
      { "matcher": "*",
        "hooks": [{ "type": "command", "command": "sentinel hook", "timeout": 3600 }] }
    ],
    "PostToolUse": [
      { "matcher": "*",
        "hooks": [{ "type": "command", "command": "sentinel hook-done", "timeout": 30 }] }
    ],
    "PostToolUseFailure": [
      { "matcher": "*",
        "hooks": [{ "type": "command", "command": "sentinel hook-done", "timeout": 30 }] }
    ],
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command", "command": "sentinel hook-done", "timeout": 30 }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "sentinel hook-done", "timeout": 30 }] }
    ]
  }
}
```

The `hook-done` timeout is not part of the contract; the command needs a few
seconds at most. The installer matches its own entries by the command name, so it
also replaces older entries such as a bare `PermissionRequest` registration or a
full path to `sentinel`.

### Adding them by hand

Prefer the script. If you edit the file yourself, remember that Claude Code merges
hooks from user, project and local settings, so registering the same command in two
places runs it twice.

## Verifying

```sh
jq '.hooks | map_values(map(.hooks[].command))' ~/.claude/settings.json
echo '{"session_id":"x","hook_event_name":"Stop"}' | sentinel hook-done; echo "exit $?"
```

The second command exits 0 and prints nothing whether or not the hub is reachable.
This behavior was checked against Claude Code 2.1.310. The contract belongs to
Claude Code, so re-check it after upgrades. The reasoning is in
[ADR-0003](adr/0003-gate-claude-code-permissions-with-a-permissionrequest-command-hook.md).
