# ADR-0003: Gate Claude Code permissions with a PermissionRequest command hook

Status: Accepted

## Context

The most frequent thing a Claude Code agent waits on me for is a permission
prompt. Interactive sessions stall at the terminal until I come back. Headless
sessions and background subagents can't prompt at all, so their calls are denied.
Claude Code exposes hooks at several points in this flow. I tested one on Claude
Code 2.1.310 with a hook that slept before answering:

- The terminal prompt appears while a `PermissionRequest` hook is still running.
- A decision from the hook closes the open terminal prompt.
- Answering in the terminal first sends the hook process `SIGTERM`.

## Options considered

**`Notification` hook on `permission_prompt`.** It fires after the prompt has been
idle for about six seconds. Rejected because notification hooks can't return a
decision, so it could alert me but I couldn't answer from the phone.

**`PreToolUse` hook.** It can allow or deny. Rejected because it fires for every
tool call, whether or not that call would have needed permission, so Sentinel
would have to reimplement Claude Code's permission rules to know when to ask.

**`PermissionRequest` hook of type `http`, posting straight to the hub.** No CLI
would be involved. Rejected because the hook would block on one HTTP request for
the whole wait, and I don't know what Claude Code does with the in-flight request
when I answer at the terminal. The command hook's `SIGTERM` is a verified,
explicit cancel signal. This could be revisited if the HTTP hook's cancellation
behavior is documented.

**`PermissionRequest` hook of type `command`, running `sentinel hook`.** It fires
exactly when Claude Code would prompt, it can allow, deny, rewrite input or save
rules, and it gets a cancel signal.

## Decision

`sentinel hook` ships as a `PermissionRequest` command hook. It creates an
`authorize` request, waits for the answer, prints the decision JSON, and cancels
the request on `SIGTERM`. "Always allow" echoes Claude Code's own
`permission_suggestions` back as `updatedPermissions`. If the hub is unreachable,
the hook exits without a decision and the terminal prompt stays in charge.

## Consequences

- Interactive sessions get a race: whichever of the terminal and Sentinel answers
  first wins. Prompts I answer at the keyboard still notify my devices briefly,
  and are withdrawn as soon as the terminal answers. (The hook first used a
  10-second grace period to avoid that. I dropped it: the brief notification
  isn't a concern, and the delay was.)
- Headless sessions and background subagents can now be approved remotely. They
  also depend on the hub: if it is down, their gated calls are denied.
- The hook timeout (600 seconds by default) caps how long a prompt can wait.
  The hook sets 3600. I haven't tested whether there's an upper bound.
- `deny` rules still win over a hook's allow, which is the behavior I want.
- Network requests from sandboxed commands don't fire `PermissionRequest`, so
  Sentinel can't approve them.
- The hook contract belongs to Claude Code and can change. `sentinel hook` should
  have a test fixture built from real hook input, and the race behavior above
  should be re-checked after Claude Code upgrades.

## Amendment: other prompts, and withdrawal

`PermissionRequest` also fires for tools that aren't permissions. The hook now
tells them apart by `tool_name`:

- `AskUserQuestion` becomes one `decision` request per question, with the
  question's options (a typed reply is the "Other" answer). The hook allows the
  call with `updatedInput` carrying the original questions plus an `answers` map.
  Multi-select questions take one pick or a comma-separated typed reply.
- `ExitPlanMode` becomes a `decision` request holding the plan, with Approve and
  Keep planning. Keep planning denies with the typed reply as the message.
- Everything else stays an `authorize` request.

If any request in a call is unanswered or expires, the hook prints nothing and the
terminal prompt stays in charge. The hook withdraws its requests when it gets
`SIGTERM`, `SIGINT` or `SIGHUP`, or when its parent process changes (the session
died), and the hub retracts them from every device. Returning `updatedInput` for
`AskUserQuestion` from `PermissionRequest` follows the documented `PreToolUse`
shape and still needs a live check after Claude Code upgrades.

The `SIGTERM` assumption did not hold in the desktop app. A real `AskUserQuestion`
answered in the app left the hook running and the request pending on the Mac. So
`sentinel hook-done` is wired to `PostToolUse`, `PostToolUseFailure`,
`UserPromptSubmit` and `Stop`. After a finished tool call it cancels that
session's pending requests whose titles match the call; after a new prompt or the
end of a turn it cancels all of the session's. A prompt denied in the terminal is
therefore withdrawn at the next prompt or turn end, not immediately.

