# ADR-0004: Build native clients on a shared Swift package

Status: Accepted

## Context

The clients have to read local machine state (input idle time, screen lock,
sleep), show actionable notifications that get through Focus, require Face ID or
Touch ID before an approval, and receive APNs pushes. The Mac and the iPhone show
the same requests with the same actions. The Watch needs to show and answer
prompts.

## Options considered

**An off-the-shelf push app (ntfy, Pushover).** No client code to write, and both
support action buttons. Rejected because neither can read Mac presence, so
presence routing (ADR-0002) is impossible. Neither can retract a prompt once it's
answered elsewhere, or require device authentication before an approval.

**A web app or PWA.** One codebase. Rejected because a web app can't read idle
time or lock state on macOS, and its notifications lack time-sensitive delivery
and authentication-gated actions.

**Native SwiftUI apps for macOS and iOS, sharing a Swift package.** These apps get
full access to `CGEventSource`, `NSWorkspace`, `UserNotifications`,
LocalAuthentication and APNs. The models, API client and notification categories
are written once in `SentinelKit`.

**A dedicated watchOS app.** It could handle free text and long option lists from
the wrist. Deferred, not rejected: iOS mirrors actionable notifications to the
Watch when the phone is locked, which covers the common case.

## Decision

The clients are a SwiftUI menu bar app for macOS and a SwiftUI app for iOS, both
on a local `SentinelKit` package. In v1, the Watch relies on mirrored
notifications.

## Consequences

- An Apple Developer Program membership is required, for APNs, the Time Sensitive
  Notifications entitlement, and installing on devices.
- Notification categories are defined once in `SentinelKit` and registered by both
  apps, so an option layout can't drift between platforms.
- The Mac app is a login item with an always-open WebSocket. It doesn't use APNs.
- Mirrored Watch notifications show only the notification's own actions. A request
  that needs free text or more than a few options has to be answered on the phone
  or Mac until a watchOS app exists.
- The JSON API is the contract between `SentinelKit` and the Go hub. A change to
  either side means updating both.
