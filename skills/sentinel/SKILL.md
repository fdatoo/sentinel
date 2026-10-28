---
name: sentinel
description: Ask the user for a decision, an authorization or a real-world action through Sentinel, and wait for the answer without polling. Use whenever work is blocked on the user (a PR review, a merge, plugging in hardware, approving a risky step, choosing between options) instead of stopping to ask in the terminal.
---

# Sentinel

Sentinel delivers a request to whichever Mac the user is using, and falls back to
their iPhone and Watch. The `sentinel` CLI creates the request and blocks until
it resolves. Use it whenever you would otherwise stop and wait for the user.

## How to wait

Always run `sentinel ask ... --wait` as a background Bash command
(`run_in_background: true`). The harness wakes you when it exits. Keep doing
any work that doesn't depend on the answer. Never poll in a loop.

The resolved request is printed as JSON on stdout. The exit code is the outcome:

| Exit | Meaning |
|---|---|
| 0 | positive: option chosen, approved, done, or the `--until` check passed |
| 1 | denied, "can't", or an option marked `--negative` |
| 2 | expired |
| 3 | cancelled |
| 4 | error or hub unreachable: fall back to asking in the terminal |
| 5 | still pending when `--timeout` ran out |

Read `.response.text` for any note the user typed.

## Kinds

- `decision`: pick an option. `--option id=Label` (repeat), `--text` for a free reply.
- `authorize`: approve or deny a risky step. Approving needs Face ID or Touch ID.
- `action`: the user does something outside the session, then taps Done or Can't.

## Waiting on something that happens elsewhere

When the thing you need shows up somewhere other than Sentinel, such as a PR
review, a merge or a CI result, add `--until '<check>'`. The CLI runs the shell
check every `--every` (default 1m). When it exits 0, the request is withdrawn
from the user's devices and `sentinel` exits 0. If the user taps Done or Can't first,
that wins. Make the check cheap, quiet and idempotent.

A PR review on Gitea (the host here is a placeholder), satisfied by a submitted
review from the reviewer on the current head commit:

```sh
sentinel ask --kind action \
  --title "Review PR #42: add retry to the uploader" \
  --body "https://gitea.example.com/owner/repo/pulls/42" \
  --expires 72h --wait --every 2m \
  --until 'api=https://gitea.example.com/api/v1/repos/owner/repo/pulls/42
    head=$(curl -fsS -H "Authorization: token $GITEA_TOKEN" $api | jq -r .head.sha)
    curl -fsS -H "Authorization: token $GITEA_TOKEN" $api/reviews |
      jq -e --arg h "$head" "any(.[]; .user.login == \"reviewer-login\" and .commit_id == \$h and .state != \"PENDING\")" >/dev/null'
```

A PR review on GitHub:

```sh
sentinel ask --kind action --title "Review PR #42" --body "https://github.com/o/r/pull/42" \
  --expires 72h --wait --every 2m \
  --until 'gh pr view 42 -R o/r --json headRefOid,reviews |
    jq -e ".headRefOid as \$h | any(.reviews[]; .author.login == \"reviewer-login\" and .commit.oid == \$h)" >/dev/null'
```

Use whatever forge credentials you already have. After the command exits 0,
read the review before continuing: a passing check means the user reviewed, not that
they approved.

## Writing a good request

- Title: one line that makes sense on a lock screen. Say what you need, not
  what you did.
- Body: markdown with the link and the context the user needs to act without
  opening the terminal. Keep secrets out, or pass `--sensitive`.
- `--label` names you (defaults to `$SENTINEL_LABEL`, else "agent"). Use the
  project or task name.
- `--urgency high` only when you are fully blocked and it can't wait: it
  reaches the phone after 1 minute and re-alerts every 5. `low` only shows on
  an active Mac. `normal` suits most things, reviews included.
- `--expires` should match how long the answer stays useful (default 24h).
- If you no longer need the answer, run `sentinel cancel <id>` so it disappears
  from the user's devices.

## Permission prompts

Tool permission prompts already reach Sentinel through the `PermissionRequest`
hook. Don't wrap them in `sentinel ask` yourself.
