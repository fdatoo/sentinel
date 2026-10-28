# ADR-0002: Route by presence and escalate to the phone

Status: Accepted

## Context

A request should reach me on the device I'm actually using. At a desk that is one
of several Macs, and away from a desk it is the iPhone, and through mirroring the
Watch. Notifications I'm not going to act on, such as my phone buzzing while I'm
typing on a Mac, are noise and teach me to ignore Sentinel. A request I don't see
at all stalls an agent indefinitely.

## Options considered

**Broadcast to every device at once.** This is the simplest option, needs no
presence tracking, and nothing is ever missed. Rejected because every request
would buzz my phone and wrist while I'm sitting at the Mac that already shows it.

**Phone only.** One target, which always reaches me. Rejected because at a desk,
answering on the Mac I'm already using is faster and can show long bodies
properly.

**Presence first, escalate on silence.** Each Mac reports idle time, lock state,
sleep and connection status. The hub delivers to the current Mac, then escalates
to the phone if the request goes unanswered or the Mac stops being active.

## Decision

The hub routes each request to the most recently used active Mac. Active means
unlocked, awake, idle under 120 seconds, and heartbeat fresh within 45 seconds. If
no Mac is active, the request goes straight to the iPhone. If it goes unanswered
on the Mac, it escalates after 3 minutes (normal urgency) or 1 minute (high
urgency), or immediately if that Mac becomes inactive. When any device answers,
the hub retracts the prompt everywhere else.

## Consequences

- The Mac app must run all the time (as a login item) and hold a WebSocket. A Mac
  without the app running is invisible to routing, which fails safe toward the
  phone.
- Escalation timers must survive a hub restart, so their deadlines are persisted.
- Retraction on iOS is best effort, because background pushes are throttled. The
  app reconciles when it opens, and a late answer gets a clear "already answered
  on <device>".
- The timings are guesses and will need tuning. They live in hub configuration,
  not in code.
- Using a device that isn't a Mac, such as an iPad, doesn't count as presence. If
  I'm on one, requests fall through to the phone.
