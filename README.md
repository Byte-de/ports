# Byte Ports

Your dev setup. At a glance.

A native macOS utility for discovering and managing local development servers,
AI agents and projects. Built with SwiftUI and AppKit. Free and open source.

[Website](https://ports.byte.de) · [Releases](https://github.com/Byte-de/ports/releases) · [Report a bug](https://github.com/Byte-de/ports/issues)

## Requirements

The 1.0.0 release supports **macOS 26 or later on Apple Silicon**. The app UI is
currently German. Intel Macs, earlier macOS releases, remote processes and
container internals are outside the supported release scope.

## Features

- Discover local servers, ports and AI agents automatically.
- Group services by project folder and save favourites.
- Save launch commands, inspect their output and restart managed services.
- Pause, resume or stop processes with identity and ownership checks.
- Use a compact window, menu bar panel or optional notch panel.
- Share an HTTP server through a temporary Cloudflare Tunnel; copy its URL and
  stop sharing directly from the service row.
- Onboarding, keyboard access, Reduce Motion and Reduce Transparency support.
- Manually check for new releases from the app menu or Settings.

## Install

Download the **Byte-Ports.dmg** asset from a published GitHub release and drag
**Byte Ports.app** into Applications. Public release assets are Developer ID
signed, notarized and stapled. Do not bypass Gatekeeper to install a build.

Once the 1.0.0 release is published, the Byte Homebrew tap also provides:

```sh
brew install --cask byte-de/tap/byte-ports
```

## Privacy and sharing

Discovery reads your user's local process information and TCP listeners. Ports
has no account, telemetry, chat-content access or API-key access. Preferences,
project paths and launch commands are stored locally. Logs from app-launched
services are buffered in memory; external processes do not expose historical
stdout through Ports. Activity is session-local and bounded.

Sharing starts only after a user action and a first-use explanation. It exposes
the selected HTTP server through Cloudflare to **anyone with the link**. There is
no additional authentication in Ports 1.0.0. Stop sharing from the service row;
quitting Ports also stops its tunnels. The bundled supervisor stops the tunnel
if Ports exits unexpectedly. No existing cloudflared configuration is changed.
Do not share secrets, private source trees or unprotected admin interfaces.

While a share is active, the Ports icon in the menu bar turns into a globe and
the compact notch panel shows a globe too. If you hide the Ports item in
System Settings › Menu Bar, that indicator is hidden with it; the service row
and, when enabled, the notch panel still show the share.

[Cloudflare Quick Tunnels](https://developers.cloudflare.com/tunnel/get-started/quick-tunnels/)
are intended for development, with temporary hostnames, no uptime guarantee,
a 200 in-flight request limit and no SSE support. Some dev servers require an
explicit allowed-host setting; configure the exact preview hostname rather than
disabling host checks globally.

Only the manual update check contacts GitHub. Download and installation remain
under your control; there is no automatic installer. The website's
[privacy notice](https://ports.byte.de/datenschutz/) describes hosting and these
optional network connections.

## Build and test

Requires a Swift 6 toolchain and macOS 26 SDK. Scripts use local toolchain
selection; they never change global Xcode settings.

```sh
Scripts/check.sh
Scripts/build-app.sh "/tmp/ports-local/Byte Ports.app"
```

Local builds use ad-hoc signing by default. A public release requires a Developer
ID identity and notarization credentials; see [Releasing](docs/RELEASING.md).
Generated products and caches stay outside the source directory. Override with
`PORTS_BUILD_DIR`, `PORTS_SDK`, `DEVELOPER_DIR` or `PORTS_CONFIGURATION` as needed.

For isolated manual testing, launch the executable with
`--state-directory /tmp/ports-test-state`. `--demo` uses sample data and disables
process actions and sharing. `--onboarding` opens the introduction. Debug-only
motion inspection uses `PORTS_MOTION_PREVIEW`; release builds ignore it.

## Data and migration

Preferences live in `~/Library/Application Support/Byte Ports/preferences.json`
with user-only permissions. The first launch can migrate settings from
pre-release builds named Byte Relay (`Byte Relay` directory) or, failing that,
the internal prototype's `DevScope` directory, without removing the original
file. Existing Byte Ports settings take precedence. Invalid or newer-format files are
preserved and saving is disabled until the problem is resolved. Back up the file
before repairing or removing it; restarting the app then retries loading.

## Architecture

`PortsCore` contains discovery, parsing, process identity validation, persistence,
tunnel lifecycle, release metadata validation and deterministic transition state.
`PortsApp` owns the SwiftUI UI and AppKit presentation coordination. `ProcessBridge`
provides narrow C access to macOS process APIs. `TunnelRunner` supervises only the
cloudflared process started by Ports. `PortsDiagnostics` provides fixture-based
integration checks. No privileged daemon or shell installer is used.

A listener is evidence of an open port, not an HTTP health check. Agent detection
is process-based and does not imply access to a task's internal progress.

Stopping a launched command also stops the processes it started, including ones
that outlived their parent. Detached daemons, which leave the command's session,
are left alone and do not keep the command marked as running.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md), the
[changelog](CHANGELOG.md), and [verification notes](docs/VERIFICATION.md).

## Licence

App source: MIT. Byte names and marks identify this project and are not a grant
of endorsement. Bundled cloudflared and its dependencies retain their respective
licences, included in `Resources/ThirdParty` and every packaged app.
