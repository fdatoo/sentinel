# ADR-0001: Self-host the hub in Go on the tailnet

Status: Accepted

## Context

Sentinel needs one always-reachable service that owns every request, runs its
escalation timers, holds the Macs' presence connections, and sends APNs pushes to
the iPhone. Every device involved (the Macs, the iPhone, and the machines agents
run on) is already on my tailnet. The service needs durable timers, because a
restart must not drop an escalation, and a single source of truth for "first
answer wins".

## Options considered

**Cloudflare Workers with a Durable Object per request.** This option fits the
problem well: a DO alarm is the fallback timer, single-threaded DOs give
compare-and-set for free, and hibernatable WebSockets hold the Mac connections. It
is reachable from anywhere without a VPN. On the other hand, it puts approval
traffic for my machines on a third-party platform. That would have called
for per-device response signing, so a compromised hub couldn't forge approvals.
It also carried an unverified risk: APNs requires HTTP/2, and I wasn't sure a
Worker's outbound `fetch` could speak it. Rejected because reach from anywhere buys
nothing when every device is on the tailnet anyway.

**Self-hosted Swift server (Hummingbird or Vapor).** It would share model types
with the Apple clients. Rejected because `tsnet`, which gives the hub tailnet
identity for free, exists only for Go, and because I prefer Go for the backend.

**Self-hosted Go service, embedded in the tailnet with `tsnet`.** The hub joins the
tailnet as its own node, so it has a stable name and listens nowhere else.
`LocalClient.WhoIs` attributes every request to a node and user, which replaces
both agent tokens and device enrollment keys. APNs is a plain outbound HTTP/2 call
from Go.

## Decision

The hub is a Go service that embeds `tsnet` and stores state in SQLite. It runs
on an always-on host I own. The CLI lives in the same Go module.

## Consequences

- Authentication comes from the tailnet: ACLs decide reachability, and `WhoIs`
  decides who is calling. The hub has no token management.
- Per-device response signing is no longer needed for v1, since the hub is on
  hardware I control.
- The hub needs an always-on host, not a laptop. Timers live in SQLite and are
  re-armed on start.
- The iPhone needs Tailscale connected to answer. The push still arrives through
  APNs, but the answer travels over the tailnet. VPN On Demand on the phone and a
  clear "hub unreachable" error in the app cover this.
- Agents running outside the tailnet (cloud containers, CI) must join it, for
  example with ephemeral auth keys, before they can use Sentinel.
- Model types are defined twice, once in Go and once in Swift. The JSON API in the
  spec is the contract between them.
