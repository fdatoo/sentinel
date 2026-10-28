# Development

## Build and test

```sh
cd hub
go vet ./... && go test -race ./...
go build -o bin/ ./cmd/sentinel-hub ./cmd/sentinel
```

The Swift package has its own tests: `cd apple/SentinelKit && swift test`.

## Dev mode

`sentinel-hub --dev` serves plain HTTP on `127.0.0.1:7878` and takes the caller's
identity from the `X-Sentinel-Node` and `X-Sentinel-Host` headers. The CLI sends
them from `SENTINEL_NODE` and `SENTINEL_HOST`, so one machine can play agent, Mac
and phone:

```sh
sentinel-hub --dev --state-dir /tmp/sentinel-dev &
export SENTINEL_URL=http://127.0.0.1:7878
SENTINEL_NODE=me sentinel register
SENTINEL_NODE=agent sentinel ask --kind authorize --title "Test" --wait &
SENTINEL_NODE=me sentinel answer "$(SENTINEL_NODE=me sentinel list --json | jq -r '.requests[0].id')" approve
```

Dev mode listens only on loopback and never joins the tailnet. The apps have a dev
node ID setting for pointing them at a dev hub.

## Xcode project

The project is generated from `apple/project.yml` and the result is checked in.
After changing `project.yml`, run `xcodegen generate` in `apple/`.

Signing values live outside the project. `apple/Config/Signing.xcconfig` sets
placeholder defaults and includes `Local.xcconfig`, which git ignores, for your team
ID and bundle ID. See the Apple section of [install.md](install.md).
