# Byte Ports

Your dev setup. At a glance.

A native macOS menu bar utility for discovering and managing local development
servers and AI agents. Built with SwiftUI and AppKit. Free and open source.

[Website](https://ports.byte.de) · [Releases](https://github.com/Byte-de/ports/releases) · [Report a bug](https://github.com/Byte-de/ports/issues)

## Requirements

The 1.0.0 release supports **macOS 26 or later on Apple Silicon**. Intel Macs,
earlier macOS releases, remote processes and container internals are outside the
supported release scope.

The app is in English and German and follows the macOS language, including a
per-app language set in System Settings › General › Language & Region ›
Applications. Other languages show English.

Byte Ports lives in the menu bar, with no Dock icon and no ⌘-Tab entry. Open it
from its menu bar icon, with ⌃⌥⌘R from any app, or by launching it again from
Finder or Spotlight. Right-click or Control-click the icon for Open Byte Ports,
Settings… and Quit Byte Ports. An unbundled build started with `swift run`
shows a Dock icon and English text, because the menu-bar-only setting and the
German text come with the app bundle.

## Features

- Discover local development servers, TCP listeners and AI agents automatically.
- Servers, Agents and Actions tabs, with services of one project folder next to
  each other. Activity and Settings open from the header.
- One panel: a floating window that remembers its position, or the notch panel
  at the top of the screen instead.
- Save launch commands as actions, edit them, follow their output live and
  restart them in place, without a second copy. Finished runs can be removed
  from the list. Commands run in zsh with your shell's environment variables.
- Pause, resume or stop processes with identity and ownership checks. A
  launched service that ignores a stop for 15 seconds shows "Not responding"
  and offers Force Stop. Agents can be quit after a confirmation: apps such as
  Claude quit as with ⌘Q, command-line agents receive SIGTERM.
- Quitting Byte Ports stops the services it launched, after a confirmation, and
  offers Force Quit for any that don't respond.
- Share a local HTTP server through a temporary Cloudflare Quick Tunnel. Its
  link is copied as soon as it is ready, a globe in the menu bar and the notch
  shows the share, and sharing stops from the service row.
- Open a command-line agent's project folder in your preferred terminal:
  Terminal, iTerm2, Ghostty or Warp.
- Open at login. Check for new releases with Check Now or an opt-in weekly
  check; a small dot on the settings gear marks a newer version.
- Keyboard shortcuts: ⌘1–⌘3 switch tabs, ⌘F searches, ⌘[ goes back, ⌘, opens
  Settings, ⌘N adds an action, ⌘R refreshes and ⌘W closes the window.
- Introduction, Full Keyboard Access, VoiceOver, Reduce Motion and Reduce
  Transparency support.

## Install

Download [Byte-Ports.dmg](https://github.com/Byte-de/ports/releases/latest/download/Byte-Ports.dmg)
from the latest release and drag **Byte Ports.app** into Applications. Release
assets are Developer ID signed, notarized and stapled. Do not bypass Gatekeeper to
install a build.

With Homebrew:

```sh
brew install --cask byte-de/tap/byte-ports
```

## Privacy and sharing

Byte Ports has no account and no telemetry, and it does not read chat contents.
Discovery reads your user's local processes and TCP listeners directly from
macOS (libproc), without running `lsof`. Preferences, project paths and launch
commands are stored locally. Output of services the app launched is kept in
memory, the last 256 KB per action; external processes do not expose historical
stdout through Byte Ports. Activity is session-local and bounded.

### Launched commands

Commands you launch run in `/bin/zsh` with your shell's environment variables,
as in Terminal, for example PATH and variables from your `.zshrc`. Aliases
aren't available. To read these variables, the first start after the app
launches runs your login shell once as an interactive shell on your Mac, and
again only after one of its startup files changes or, if that read failed, at
the next start at least five minutes later. The variables may contain
credentials. They stay in memory, are passed only to the commands you launch,
and are never stored, logged or transmitted.

Stopping a launched command also stops the processes it started, including ones
that outlived their parent. Detached daemons, which leave the command's session,
are left alone and do not keep the command marked as running. Processes started
elsewhere keep running when Byte Ports quits.

### Sharing

Sharing starts only after a user action and a first-use explanation. Only HTTP
servers reachable on 127.0.0.1 or ::1 can be shared: databases and caches such
as PostgreSQL or Redis are never offered, and a server that listens only on a
LAN address can't be shared. Before a share starts, the app sends exactly one
HEAD request to the server over the loopback interface to check that it speaks
HTTP; this check does not leave your Mac. The bundled cloudflared then exposes
the server through a Cloudflare Quick Tunnel to **anyone with the link**.
Cloudflare is contacted only while a share is active. There is no additional
authentication in Byte Ports 1.0.0.

The link is copied to the clipboard as soon as it is ready, within 60 seconds of
the click; a link that arrives later stays in the service row. Stop sharing from
the service row; quitting Byte Ports also stops its shares. The bundled
supervisor stops the tunnel if Byte Ports exits unexpectedly. No existing
cloudflared configuration is changed. Do not share secrets, private source trees
or unprotected admin interfaces.

While a share is active, the Byte Ports icon in the menu bar turns into a globe
and the compact notch panel shows a globe too. If you hide the Byte Ports item
in System Settings › Menu Bar, that indicator is hidden with it; the service row
and, when enabled, the notch panel still show the share.

[Cloudflare Quick Tunnels](https://developers.cloudflare.com/tunnel/get-started/quick-tunnels/)
are intended for development, with temporary hostnames, no uptime guarantee,
a 200 in-flight request limit and no SSE support. Some dev servers require an
explicit allowed-host setting; configure the exact preview hostname rather than
disabling host checks globally.

### Update check

Byte Ports contacts GitHub's API only to look for a newer release: when you
choose Check Now in Settings, or, only if you turn on "Check for updates weekly"
(off by default), once every seven days. A weekly check that fails is retried
after six hours or at the next launch. Each check is one request to
`https://api.github.com/repos/Byte-de/ports/releases/latest` without device or
user identifiers; as with any connection, GitHub sees your IP address. The app
stores only the time and result of the last check locally. It never downloads or
installs anything: Download ↗ opens the release page, and you install the update
yourself.

The website's [privacy notice](https://ports.byte.de/datenschutz/) (in German)
describes hosting and these network connections.

### Logging

Byte Ports writes to the macOS unified log under the subsystem `de.byte.ports`.
Paths, working directories, commands, project names, share links and error
descriptions appear only as `<private>`. Environment values, external arguments,
service output and search text are never logged.

## Support

Report problems on [GitHub Issues](https://github.com/Byte-de/ports/issues).
Paste the app's log of the last hour into the report's Diagnostics field:

```sh
log show --predicate 'subsystem == "de.byte.ports"' --last 1h --info
```

Private values already appear as `<private>`; read the output and redact
anything else before you share it. Per-scan summaries appear only while
streaming with
`log stream --level debug --predicate 'subsystem == "de.byte.ports"'`.
Report security problems privately as described in [SECURITY.md](SECURITY.md).

## Build and test

Requires a Swift 6 toolchain and macOS 26 SDK. Scripts use local toolchain
selection; they never change global Xcode settings.

```sh
Scripts/lint.sh
Scripts/check.sh
Scripts/build-app.sh "/tmp/ports-local/Byte Ports.app"
```

`lint.sh` runs strict swift-format and the log-privacy guard without a build.
`check.sh` runs the unit tests, the tunnel supervisor checks, the
`ports-diagnostics` integration, listener-parity and benchmark checks, and the
localization check. Local builds use ad-hoc signing by default. A public release
requires a Developer ID identity and notarization credentials; see
[Releasing](docs/RELEASING.md). Generated products and caches stay outside the
source directory. Override with `PORTS_BUILD_DIR`, `PORTS_SDK`, `DEVELOPER_DIR`
or `PORTS_CONFIGURATION` as needed.

For isolated manual testing, launch the executable with
`--state-directory /tmp/ports-test-state`. `--demo` uses sample data and disables
process actions and sharing. `--onboarding` opens the introduction. Add
`-AppleLanguages '(de)'` or `'(en)'` to the executable of a built app to test a
language. Debug-only motion inspection uses `PORTS_MOTION_PREVIEW`; release
builds ignore it.

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
tunnel lifecycle, release metadata validation, logging and deterministic
transition state. `PortsFeatures` holds the UI-free app policy, such as service
lists, navigation, the quit flow, the share link handoff and the update schedule,
and is unit-tested without AppKit. `PortsApp` owns the SwiftUI UI and AppKit
presentation coordination. `ProcessBridge` provides narrow C access to macOS
process APIs. `TunnelRunner` supervises only the cloudflared process started by
Byte Ports. `PortsDiagnostics` provides fixture-based integration checks. No
privileged daemon or shell installer is used.

A listener is evidence of an open port, not an HTTP health check. Agent detection
is process-based and does not imply access to a task's internal progress.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md), the
[changelog](CHANGELOG.md), and [verification notes](docs/VERIFICATION.md).

## Licence

App source: MIT. Byte names and marks identify this project and are not a grant
of endorsement. Bundled cloudflared and its dependencies retain their respective
licences, included in `Resources/ThirdParty` and every packaged app.
