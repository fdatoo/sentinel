# Shipping the apps through TestFlight

For the normal install see [install.md](install.md), step 6. This page is the
release recipe for putting both apps on TestFlight.

Both apps share one bundle ID, so one App Store Connect record covers iOS and
macOS. Create it once (New App, both platforms, with the bundle ID from
your `Local.xcconfig`). Then upload each archive with Xcode's Organizer or
`xcodebuild -exportArchive` using method `app-store-connect` and destination
`upload`. Bump `CURRENT_PROJECT_VERSION` in `apple/project.yml` for every upload and
run `xcodegen generate`. The Mac app runs in the App Sandbox, which TestFlight
requires.

The Apple account signed into Xcode needs access to the app in App Store Connect
(Users and Access). A Developer-role account without it gets "App record ... not
found" even though the record exists.

## Unsigned archive for the Mac app

Signed archiving fails when the team has no registered devices for a development
profile. Archive unsigned instead, sign the app ad hoc with its entitlements, and
let the export re-sign it for distribution:

```sh
cd apple
xcodebuild -project Sentinel.xcodeproj -scheme SentinelMac -configuration Release \
  -archivePath build/SentinelMac.xcarchive CODE_SIGNING_ALLOWED=NO archive
codesign --force --deep --sign - --options runtime \
  --entitlements SentinelMac/SentinelMac.entitlements \
  build/SentinelMac.xcarchive/Products/Applications/Sentinel.app
```

If the export fails with "Copy failed" and the distribution logs show an rsync usage
error, a Homebrew `rsync` is ahead of `/usr/bin/rsync` on `PATH`. Run the export
with `PATH=/usr/bin:/bin:/usr/sbin:/sbin`.
