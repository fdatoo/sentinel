# Security policy

## Reporting a vulnerability

Please report security problems privately, through GitHub's "Report a
vulnerability" button on the repository's Security tab. Don't open a public issue
for them. I'll acknowledge a report as soon as I can and credit you in the fix if
you want.

## What Sentinel trusts

Sentinel is meant to run on a tailnet you control, and its security rests on that:

- The hub accepts connections only on its tailnet node. Tailnet ACLs decide who can
  reach it, and the hub attributes each caller with Tailscale's `WhoIs`.
- Every node that can reach the hub can create requests. Only devices registered by
  the hub's owner can answer them.
- A registered device is trusted as a whole node. An agent running on the same
  machine as a registered Mac or CLI can answer its own requests. Run such agents on
  separate, tagged nodes.
- When a request has a `callback_url`, the hub sends the resolved request to it as
  an HTTP POST from its own tailnet identity.

The full model, including what is deliberately left out, is in the Security section
of [docs/spec.md](docs/spec.md#security).

## Supported versions

Only the latest commit on `main` is supported.
