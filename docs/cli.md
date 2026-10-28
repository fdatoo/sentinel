# CLI

`sentinel` creates requests and waits on them. Install and configure it with
[install.md](install.md), steps 4 and 5. The same binary implements the
[Claude Code hooks](hooks.md).

```sh
sentinel ask --kind authorize --title "Run the prod migration?" --wait
sentinel ask --kind decision --title "Which approach?" \
  --option a="Rewrite" --option b="Patch" --text --wait
sentinel ask --kind action --title "Plug in the YubiKey" --urgency high --wait
sentinel list
sentinel wait <id> --timeout 30m
sentinel cancel <id>
```

`--wait` prints the resolved request as JSON and exits 0 for a positive answer, 1
for deny or "can't" (or any option passed with `--negative`), 2 if it expired, 3 if
cancelled, 4 on errors and 5 if `--timeout` ran out first. Agents run it as a
background command so they can keep working.

For waits that end somewhere else, `--until` takes a shell check. When it passes,
the request is withdrawn and the CLI exits 0:

```sh
sentinel ask --kind action --title "Review PR #42" --wait --every 2m \
  --until 'test "$(gh pr view 42 --json reviews -q ".reviews | length")" -gt 0'
```

To answer from a terminal, register that machine once with `sentinel register`,
then use `sentinel answer <id> <option> [--text "..."]`. `sentinel devices` lists
registered devices.

`skills/sentinel/SKILL.md` teaches Claude Code agents when and how to use all of
this. Install it with the symlink in step 7 of the install guide.

The full command reference is in [spec.md](spec.md#cli).
