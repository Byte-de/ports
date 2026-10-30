# Release verification — 1.0.0 (build 3)

The release checklist for Byte Ports 1.0.0, build 3. Before the tag, every local gate has a status and evidence from
the candidate, and every external gate has an owner and either evidence or its blocker. Only evidence from completed
checks counts as passed: nothing is inferred from an earlier build, another machine or a similar check. Build 2
results are archived at the end and do not count for build 3.

## Candidate

| Field | Value |
| --- | --- |
| Version | 1.0.0 (build 3) |
| Commit | `fb67d27` on `byte-ports`, clean tree (evidence below added in a later commit that changes only this file) |
| Host | Mac Studio (Mac14,13), Apple M2 Max, 64 GB, macOS 26.6.2 (25G83), 811 own processes; no built-in notch display |
| Toolchain | Command Line Tools, Apple Swift 6.4 (swiftlang-6.4.0.34.1), MacOSX26.5.sdk chosen by `Scripts/toolchain.sh` |
| Signing | Developer ID Application: Nord Ventures GmbH (U2G2QZYSPC), Hardened Runtime, secure timestamp; helpers signed by the same team. Notarization: app `6e5ba454-4e9d-4e5e-837b-640a7f1b8c56`, DMG `fe0093ee-381e-4024-bf3c-ce17beb13468`, both Accepted |
| Date | 30 October 2026 |

Statuses are `open`, `pass`, `fail: <what failed>` and `blocked: <reason>`. A pass names its evidence: the command
and its result, a CI run id, or the configuration that was checked and by whom. Finding ids in brackets refer to the
review findings; the [finding map](#finding-map) lists where each one is checked.

### Setup

```sh
# A Developer ID signed candidate for §1–§4. Notarization follows in §5.
SIGN_IDENTITY='Developer ID Application: …' Scripts/build-app.sh "/tmp/ports-rc/Byte Ports.app"
# Isolated state keeps real settings untouched. Login item and migration checks say when to leave it out.
open -n "/tmp/ports-rc/Byte Ports.app" --args --state-directory /tmp/ports-rc-state
# The unified log while testing.
log stream --level debug --predicate 'subsystem == "de.byte.ports"'
```

`--demo` shows sample data and turns process actions and sharing off. `--onboarding` opens the introduction. Test
servers: `python3 -m http.server 8765`; `pkill -f 'http.server 87'` removes only those. Unless a line says otherwise,
check its text in both languages (§2.2).

## 1. Automated gates

Local runs use the release commit on the host above. CI runs the same scripts on GitHub's macOS 26 runners.

- [x] **1.1 Static checks.** `Scripts/lint.sh`: strict swift-format, then the log-privacy guard's self-test and its
  scan of `Sources`. [P3]
  Pre-candidate (28 October 2026, M6 verification, Command Line Tools toolchain): passed.
- [x] **1.2 Tests and checks.** `Scripts/check.sh`. Record:
  - Swift Testing per target: PortsCoreTests _n_ tests in _n_ suites, PortsFeaturesTests _n_ tests in _n_ suites.
  - The 4 C supervisor checks of `Scripts/test-tunnel-runner.py`: control-pipe EOF, unresponsive child, supervisor
    termination and parent crash cleanup.
  - `ports-diagnostics --integration`: TCP discovery, identity verification, pause, resume, log capture, restart,
    graceful stop, the HTTP check and cleanup.
  - `ports-diagnostics --listener-parity`: native listener discovery matches `lsof`.
  - `ports-diagnostics` (one cold and one warm scan) and `--benchmark 3`, which keeps the benchmark path working; the
    budgets are in §4.
  - The localization checker's self-test and the strict scan of `Scripts/check-localization.sh`: no missing German,
    plural parity, no German in Swift literals. [P4, P5, E2, E7, E9]

  Pre-candidate (28 October 2026, M6 verification, debug build with the Command Line Tools toolchain): passed;
  PortsCoreTests 208 tests in 25 suites, PortsFeaturesTests 86 tests in 12 suites, the 4 supervisor checks, the
  integration, listener parity over 38 listeners, and the localization check over 342 keys.
- [x] **1.3 Bundle contract.** `Scripts/validate-bundle.sh "/tmp/ports-rc/Byte Ports.app"`: version 1.0.0 and build 3
  as in `Resources/Info.plist`, LSUIElement, the developer-tools category, development region `en`, localizations
  `[en, de]` with their lproj tables, signed helpers, inert agent logos, and a log subsystem equal to the bundle id.
  Pre-candidate (28 October 2026, M6.1, ad hoc signed release and debug bundles): passed; copies without `de.lproj` or
  `en.lproj` failed with the original signature (codesign treats lproj folders as optional) and after re-signing, as
  did a bundle lacking a table from the source tree. The M6 verification's ad hoc signed `Scripts/build-app.sh`
  bundle passed it and `codesign --verify --deep --strict`, and its copy without `de.lproj` failed. [P8]
- [x] **1.4 Smoke launch.** `Scripts/smoke-app.sh "/tmp/ports-rc/Byte Ports.app"`: the app runs for 5 s in demo mode
  with a temporary state directory and logs no faults; the panel frame saved in the `de.byte.ports` defaults is put
  back afterwards, or removed if none was saved before. `Scripts/release.sh` runs it without `--skip-without-gui`.
  Pre-candidate (28 October 2026, M6.1): passed; an executable that exits, one that logs a fault, a missing executable
  and a session without a GUI failed it, and `--skip-without-gui` skipped the last case with a notice. The M6
  verification's bundle passed it, and the saved panel frame was unchanged afterwards. [P8]
- [x] **1.5 CI on the release commit.** The Check workflow passes lint, check, the release build, bundle validation
  and the smoke launch. Record the run id and whether the smoke step printed "Smoke-launched app" or the no-GUI
  notice. Blocked by 5.4.
- [ ] **1.6 Bundled cloudflared.** The "Check bundled cloudflared" workflow is green for the pinned version. Blocked by
  5.5.
- [x] **1.7 Live tunnel.** With network access, `ports-diagnostics --tunnel-integration "/tmp/ports-rc/Byte Ports.app"`
  serves a temporary localhost server through the generated public HTTPS URL with the bundled client and supervisor,
  and closing the owner pipe stops the tunnel. No user project or file is exposed. [B5c]

## 2. Product behaviour

Manual checks on the candidate from Setup.

### 2.1 Menu bar app and login launch

- [ ] **2.1.1** No Dock icon and no ⌘-Tab entry. The status item shows the port glyph and the service count. [U9, P8]
- [ ] **2.1.2** The first launch with a fresh state directory opens the introduction in the window: visible in front,
  and key when the system grants activation, also when another app was active. [U9, U10]
- [ ] **2.1.3** A normal launch and launching the running app again (Finder, Spotlight, `open`) show the home surface:
  the window with the notch off, the expanded notch panel with it on. Visible in front, and key when the system grants
  activation. [U9]
- [ ] **2.1.4** A click on the status item toggles the home surface. When the window is behind other apps or on
  another Space, the click brings it forward instead of hiding it. Right-click and Control-click show Open Byte Ports,
  Settings… and Quit Byte Ports; Settings… opens settings in the panel and no other window appears. VO-Space on the
  item toggles the panel. [U9]
- [ ] **2.1.5** Notch off: the panel is a floating squircle window. The first time, after
  `defaults delete de.byte.ports "NSWindow Frame BytePortsPanel"`, it is centred on the screen with the menu bar item.
  After moving it, closing it (close button, ⌘W or the item) and quitting, it comes back at the same position. ⌘M does
  nothing. [U9]
- [ ] **2.1.6** Notch on: the item expands and collapses the notch panel, with squircle corners; no window or popover
  ever appears as well. Turning the notch on moves an open window into the notch; turning it off with the panel open
  shows the window at its last position. `--onboarding` runs in the window and, with the notch chosen, hands over to
  the notch. [U9, U12]
- [ ] **2.1.7** ⌃⌥⌘R in any app toggles the home surface: visible in front, and key when the system grants activation.
  macOS asks for no Accessibility permission. Turned off in Settings, the key does nothing. While another app holds the
  combination, Settings says "Already in use by another app." [U9]
- [ ] **2.1.8** Launch at login, with the candidate copied to /Applications and without `--state-directory` (this
  instance uses the real settings): "Open at login" adds Byte Ports to System Settings › General › Login Items. After
  logging out and in, the app starts silently, with the status item only. Turning it off removes the entry. A copy run
  from a disk image or an App Translocation path shows the switch disabled with "Move the app to the Applications
  folder first." [P1]
- [ ] **2.1.9** Quitting needs no Dock icon: the item's menu, the Settings footer, ⌘Q while the panel is key and
  `osascript -e 'quit app "Byte Ports"'` each start the quit flow of §2.4. [U9, B1]
- [ ] **2.1.10** With the Byte Ports item hidden in System Settings › Menu Bar, launching the app again shows the
  panel, and ⌃⌥⌘R still works. [U9]
- [ ] **2.1.11** In light and dark appearance, the window and the notch show only the dark squircle surface: no white
  frame or background, no system shadow, no square corners. [U9]

### 2.2 Both languages

- [ ] **2.2.1** Language matrix on the packaged candidate. Quit the running candidate first, so only one instance
  runs, and keep the isolated state:
  `"/tmp/ports-rc/Byte Ports.app/Contents/MacOS/BytePorts" -AppleLanguages '(de)' --state-directory /tmp/ports-rc-state`,
  and likewise `'(de-AT)'`, `'(de-CH)'` and `'(fr, de)'`, show German; `'(en)'` and `'(fr)'` show English. [P5, P8]
- [ ] **2.2.2** Per-app language: in System Settings › General › Language & Region › Applications, set Byte Ports to
  German on an English system and to English on a German one. The next launch follows the override; without one, the
  app follows the macOS language. [P5]
- [ ] **2.2.3** In each language, walk through the introduction, the Servers, Agents and Actions tabs, the launch form
  (new, edit, delete confirmation), the output page, Activity, Settings with its footer, every confirmation (stop,
  quit agent, force stop, share, quit panel), error alerts, toasts, the status item menu and VoiceOver labels. Nothing
  is truncated or clipped at the 480 pt panel width; German shows no English and English no German, apart from
  product names and the glossary terms in [docs/LOCALIZATION.md](LOCALIZATION.md). [P5, U6]
- [ ] **2.2.4** Memory, CPU, uptime, counts and times follow the language and region, for example a decimal comma in
  German. [P5]

The copy review by native-level readers is external gate 5.13.

### 2.3 Discovery and navigation

- [ ] **2.3.1** The bottom bar has exactly three tabs: Servers · Agents · Actions (Server · Agenten · Aktionen). ⌘1, ⌘2
  and ⌘3 select them in that order, and their tooltips name the shortcut. Activity (clock) and Settings (gear) are
  pages opened from the header. There is no board, overview, projects tab, filter bar, All view, favourites, banner,
  menu bar popover or quick tooltip. [U1, B9, B13c]
- [ ] **2.3.2** The Servers tab lists everything except agents, other TCP listeners only with "Show all TCP
  listeners". The Agents tab lists agents with their brand logos. An agent with its own port appears once, as an
  agent. [U1, B8]
- [ ] **2.3.3** Counts agree: the status item shows the sum of the two tab lists and of the notch's agent and server
  counts, and "Show all TCP listeners" raises them by the same number. With `--demo` the status item shows 6 and the
  notch 3 and 3. [B8]
- [ ] **2.3.4** Services of one project folder sit next to each other. In the Servers tab, servers come before other
  listeners. Services without a project, such as Claude.app, come last. [B7, B13a]
- [ ] **2.3.5** Desktop apps such as ChatGPT or Claude show "Desktop app" and offer no project folder action. A server
  started in the home folder (`cd ~ && python3 -m http.server 8766`) counts as a project. [B3]
- [ ] **2.3.6** The clock opens Activity, the gear Settings, a row's chevron its details and an action its output,
  each over the list and with a back button. Back and ⌘[ return to the page they came from, and the list underneath
  keeps its scroll position. Selecting the current tab again returns to its root. [B9, B13b]
- [ ] **2.3.7** One address per port:
  `node -e "const h=require('http');h.createServer((q,s)=>s.end('ok')).listen(8771,'127.0.0.1');h.createServer((q,s)=>s.end('ok')).listen(8771,'::1')"`
  shows one row `:8771  localhost` under ADDRESSES, with one share action: both loopbacks read as localhost. Open and
  Copy use `http://127.0.0.1:8771`. [B15]
- [ ] **2.3.8** The header stays calm: no counts, no refresh button, nothing dims or blinks while scans run. With
  "Automatic detection" off, the orange "Paused" badge shows on every page and the empty list explains the pause with
  Resume. A click on the badge resumes detection and scans at once. The pause survives a relaunch. [U2, B6, B16]
- [ ] **2.3.9** ⌘R scans at once: a `Scan:` line appears in the debug log right away. Holding ⌘R (key repeat) gives
  at most one `Scan:` line per repeat, and the panel stays responsive. A scan is too short to press keys during it, so
  the contract that requests during a running scan share exactly one trailing scan is checked by
  `RefreshCoalescerTests` in 1.2. [B14]
- [ ] **2.3.10** Hover or keyboard focus on a row reveals copy, share and stop or quit, and nothing moves; otherwise
  the uptime shows. A click opens a web server in the browser, brings a desktop agent to the front and opens a CLI
  agent's details. A process the app can't control shows no stop anywhere, including the context menu and the
  details; agents show the quit button of 2.4.11 instead. Stop confirmations are short, with "PID n" at the bottom
  left. [U3, U5]
- [ ] **2.3.11** Scan failures need a debug build, because only debug builds read the failure switch. Quit the
  candidate, build `PORTS_CONFIGURATION=debug Scripts/build-app.sh "/tmp/ports-debug/Byte Ports.app"` and open it
  with `--state-directory /tmp/ports-rc-state` as in Setup. `touch "$TMPDIR/ports-fail-scans"` makes every scan fail:
  an inline warning shows on the Servers and Agents roots only, never a modal. `rm "$TMPDIR/ports-fail-scans"` clears
  it with the next scan. Quit the debug copy before going on with the candidate. Error alerts are titled by context.
  For "Couldn't stop", press stop on a test server's row, leave the confirmation open, run `pkill -f 'http.server 87'`
  in Terminal, then confirm Stop. "Couldn't share" follows from 2.5.4. [B17]
- [ ] **2.3.12** Quit, run `echo '{' > /tmp/ports-rc-state/preferences.json` and launch. The defaults apply, so the
  introduction opens first. Close it with Esc (the close button), and the panel shows "Couldn't read settings". Skip
  instead reports "Settings couldn't be saved" with Try Again and Continue Without Saving, and continuing clears the
  read error. Changing a setting then reports "Settings not saved", and the file still holds only `{`. A build-2 file,
  `{"version":1,"preferences":{"refreshInterval":3,"showOtherListeners":false,"showNotch":false,"launchConfigurations":[],"agentRules":[],"favoriteProjects":[],"hasCompletedOnboarding":true,"hasAcknowledgedPublicSharing":false}}`,
  loads with every newer setting at its default: weekly check off, Terminal as the terminal, ⌃⌥⌘R on and automatic
  detection on. [B17, B19]
- [ ] **2.3.13** Scan cadence in the debug log: with every surface hidden, `Scan:` lines come about every 15 s.
  Opening a surface scans at once unless the list is younger than the interval, then scans at the configured
  interval. With the displays asleep (`pmset displaysleepnow`) at most one scan runs per minute, and one runs right
  after waking. No `Slow scan` (over 1000 ms) appears. Durations are informational here: warm scans are expected
  around 12–15 ms on the reference host, and the first scan after launch is cold and slower. The scan budget is 4.1.
  [E6, E1, E7]

### 2.4 Launch and quit

Create the fixtures as actions with ⌘N, in `/tmp` unless a line names another folder.

- [ ] **2.4.1** `node -v; which node` saved as an action shows the hint "Runs in zsh with your shell's environment
  variables. Aliases aren't available." The first start briefly shows "Loading shell environment…", and the output
  shows the nvm version and a path under `~/.nvm`. The next start shows no loading hint. One of your aliases fails
  with `command not found`, and the app stays usable. [B11, U5]
- [ ] **2.4.2** "Web" with `python3 -m http.server 8767`: Restart keeps the row and its output, adds
  `──── Restarted · … ────` and shows the toast "“Web” restarted". Stopping and starting it again still shows one row,
  with `──── Started again · … ────`. [B2]
- [ ] **2.4.3** Stop asks first, then shows "Stopping…" and "Stopped". `sleep 300 & sleep 300 & wait` leaves nothing
  behind: `pgrep -f 'sleep 300'` is empty. A daemon, `perl -MPOSIX -e 'fork and exit; POSIX::setsid(); sleep 300'`,
  is left alone: the row shows "Exited" and the daemon keeps running. Clean up with `pkill -f 'POSIX::setsid'`.
  [B1, E3]
- [ ] **2.4.4** `trap 'sleep 5; exit 0' TERM; sleep 600` stops within the 15 s grace, with no force offer. [B1]
- [ ] **2.4.5** `trap '' TERM; exec sleep 600` shows "Stopping…" for 15 s, then "Not responding" with only "Force
  Stop…". Its confirmation warns about data loss, and Return does nothing. Force Stop ends in "Stopped" with the toast
  "“…” force stopped". Restarting the fixture gives "“…” isn't responding and wasn't restarted."; Force Stop from
  there adds "It restarts afterwards." and the same row runs again. [B1, B2]
- [ ] **2.4.6** `echo boom; exit 1` shows "Failed · exit 1" with a toast. `echo done` shows "Exited", with an Activity
  entry only. [B1]
- [ ] **2.4.7** One-off runs sit under RUN ONCE, saved actions under SAVED. Clear Finished removes finished one-off
  runs only. The context menu offers Start, Show Output, Restart, Edit…, Copy Command, Delete… and Remove from List
  where they apply. With `--demo`, starting, stopping, restarting and removing are off. [U3]
- [ ] **2.4.8** `while :; do date; sleep 0.05; done` follows the end of its output while CPU stays low. Scrolling up
  stops following and shows "New output", which jumps back to the end. With
  `head -c 400000 /dev/zero | tr '\0' 'a' | fold -w 100; sleep 600`, the copied output starts with
  "[Older output discarded · 256 KB maximum]" and the view stays smooth. [B10, E3, E8]
- [ ] **2.4.9** Edit… changes the name or the command. While the action runs, the form says "Currently running.
  Changes apply from the next start." A duplicate name shows "An action with this name already exists." in the form.
  Delete… asks first; Return doesn't confirm and Esc cancels. A deleted running action moves to RUN ONCE and keeps
  running. [U7]
- [ ] **2.4.10** ⌘N from a server's details fills in its project folder. A row's context menu offers "New Action in
  This Folder…". Otherwise the form proposes the folder of the last successful start. [U11]
- [ ] **2.4.11** Every agent row reveals the red power button "Quit…", also for apps such as Claude and for CLIs
  inside app bundles. The confirmation says that the app quits as with ⌘Q, or that the host app (such as ChatGPT) may
  start its CLI again. An app receives a normal quit request; a CLI agent receives SIGTERM, also while paused. Apps
  offer no pause. [U3]
- [ ] **2.4.12** Without launched work, ⌘Q quits at once, with no panel. [B1]
- [ ] **2.4.13** With two running actions, quitting shows "Stop launched services?" with both names. Esc keeps
  everything running. "Stop and Quit" (Return) checks off each service, then the app quits. An active share ends too
  ("Active shares end as well."). [B1]
- [ ] **2.4.14** With the fixture of 2.4.5 and one normal action, "Stop and Quit" turns into "Some services aren't
  responding" after 15 s, with Force Quit, Cancel Quit and Keep Waiting (Return). Force Quit ends the fixture and the
  app. Cancelling in any phase keeps the app running, and new actions start again. A second quit request while the
  panel is open only brings it forward. [B1]
- [ ] **2.4.15** Every route of 2.1.9 shows the same quit panel, also with the window closed. With Terminal in front,
  `osascript -e 'quit app "Byte Ports"'` followed by a click on Cancel: the first click works. [B1, U9]
- [ ] **2.4.16** Logout, after saving all work: run
  `trap 'echo TERM >> /tmp/ports-rc-term.txt; exit 0' TERM; while true; do sleep 1; done` and log out. No panel
  appears, logout is not blocked, and afterwards the file contains `TERM`. [B1]

### 2.5 Sharing

- [ ] **2.5.1** The first share asks once, with a one-paragraph confirmation "Share this server publicly?"; Cancel
  starts nothing. Sharing works on macOS 26 with no version notice. [B5c, B13d, U5]
- [ ] **2.5.2** Every share copies its link as soon as it is ready, with the toast "Share link copied", also when
  something else was copied in between. Only a link that comes up more than 60 s after the click is offered in its
  row instead. Fixture: copy some text, run `sleep 3; pmset sleepnow` in Terminal and click Share right away, so the
  Mac sleeps before the link is ready. Wake it after more than 60 s: the row offers the link with the toast "Share is
  live · copy the link from its row", and the clipboard still holds the text. [B5b]
- [ ] **2.5.3** Within 0.5 s of a share starting, the menu bar icon turns into a globe; it returns to the port glyph
  once the last share has stopped. VoiceOver reads "Byte Ports – public share active, <count>", otherwise
  "Byte Ports, <count>". Beside a notch, the ears stay out while sharing, with an accent globe after the server count,
  and VoiceOver reads "Open Byte Ports, public share active". Demo mode shows neither. [B5a, E5]
- [ ] **2.5.4** A non-HTTP fixture,
  `printf 'import socket\ns=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.bind(("127.0.0.1",7777));s.listen()\nwhile True:\n c,_=s.accept();c.close()\n' > /tmp/nohttp.py && python3 /tmp/nohttp.py`,
  fails to share with "This service doesn't answer plain HTTP. Only local HTTP servers can be shared publicly.", and
  its row then shows "No HTTP" instead of Share. Databases such as Postgres or Redis never offer Share. A server that
  listens only on a LAN address can't be shared. [B5c]
- [ ] **2.5.5** The public link works from outside, for example on a phone on mobile data. Stopping the shared server
  closes the share with "The server or port stopped. Sharing was closed." After quitting, `pgrep -x cloudflared`
  finds nothing; after `kill -9` of the app, the supervisor stops the tunnel too. [B5c]
- [ ] **2.5.6** Details show one ADDRESSES row per port with Open, Copy and Share; a wildcard listener shows "Also
  reachable on your network" once. [B15, U5]
- [ ] **2.5.7** In a copy of the candidate without `Contents/Helpers/cloudflared`, re-signed ad hoc with
  `codesign --force --deep --sign -`, sharing fails with "The Cloudflare client is missing from this installation.
  Please download and reinstall the app." [B18]
- [ ] **2.5.8** With the Byte Ports item hidden in System Settings › Menu Bar, the globe is hidden too, as the README
  states; the service row and the notch still show the share. [B5a]
- [ ] **2.5.9** With every panel hidden, a 5-minute `Scripts/measure-resources.sh` sample with one share active
  averages no more CPU than one without it: share updates arrive as events, with no polling. [E5]

### 2.6 Updates

- [ ] **2.6.1** Finishing the introduction without touching a switch leaves "Check for updates weekly" off and
  registers no login item. Over 10 minutes and one relaunch, `nettop -m tcp -p "$(pgrep -x BytePorts)"` shows no
  connection to api.github.com, and the log has no "Update check started". [P2, U10]
- [ ] **2.6.2** Weekly check with a backdated state. Quit, then run:

  ```sh
  python3 - /tmp/ports-rc-state/preferences.json <<'PY'
  import json, sys, time
  path = sys.argv[1]
  data = json.load(open(path))
  data['preferences']['checksForUpdatesAutomatically'] = True
  # Dates count seconds from 2001-01-01; eight days back makes the weekly check due.
  data['preferences']['lastUpdateCheck'] = time.time() - 978307200 - 8 * 86400
  json.dump(data, open(path, 'w'), indent=2)
  PY
  ```

  About 20 s after launch, nettop shows one connection to api.github.com and the log shows "Update check started
  (scheduled)" and its result. After a successful check, relaunching asks nothing for 7 days. While no GitHub release
  exists, the check fails silently ("Scheduled update check failed silently"): no alert, and the check stays due.
  [P2]
- [ ] **2.6.3** Turning the weekly check on in Settings checks at once when one is due. Turned off, no request is
  made. [P2]
- [ ] **2.6.4** With `latestKnownVersion` set to `"1.0.1"` the same way, the gear shows a dot and the tooltip
  "Settings – update available (⌘,)", and Settings shows "Version 1.0.1 is available." with Download ↗ and Dismiss.
  Dismiss hides the dot for 1.0.1 only; `"1.0.2"` shows it again. [P2]
- [ ] **2.6.5** Check Now shows "Byte Ports is up to date." or "The update check failed. Please try again later."
  within 20 s, then "Last checked …". Nothing hangs, and nothing is downloaded or installed. [P2, E9]

### 2.7 Logging and redaction

- [ ] **2.7.1** After exercising §2.3–§2.6, the README's support command
  `log show --predicate 'subsystem == "de.byte.ports"' --last 1h --info` returns events from the scan, launch,
  process, tunnel, update, persistence, lifecycle and ui categories. [P3]
- [ ] **2.7.2** Paths, working directories, commands, project names, share URLs and error descriptions appear only as
  `<private>`. Counts, PIDs, ports, states, versions and exit codes are readable. Pausing and resuming an external
  server logs `Sent pause to pid …` and `Sent resume to pid …` without a path. External arguments, environment
  values, job output and search text never appear. [P3]
- [ ] **2.7.3** Per-scan `Scan:` summaries appear in `log stream --level debug` only; `log show` afterwards has none.
  [P3, E6]

### 2.8 Keyboard and accessibility

- [ ] **2.8.1** Shortcuts on all three surfaces. In the window and in the expanded notch panel, ⌘1–⌘3, ⌘F, ⌘[, ⌘,, ⌘N
  and ⌘R act on the surface whose window is key; ⌘1 in the notch switches its tab and opens no window. ⌘W closes only
  the window, and the app keeps running. The status item menu takes ⌘, and ⌘Q. While a dialog is open, none of the
  panel shortcuts acts. ⌘Q runs the quit flow everywhere. [B13c, U9]
- [ ] **2.8.2** With Full Keyboard Access (System Settings › Accessibility › Keyboard), Tab reaches the tabs, the
  header buttons, rows and their actions, the settings controls and every dialog button, with visible focus rings.
  Focus on a row reveals its actions as hover does; focus on the compact notch element shows the ears. Return and Esc
  trigger a dialog's default and cancel buttons. [U3, U12]
- [ ] **2.8.3** VoiceOver (⌘F5): the status item reads as in 2.5.3, and VO-Space toggles the panel. Tabs read their
  names; rows read name, project and state ("…, running for …" or "…, paused"); the Paused badge reads "Detection
  paused"; the introduction reads "Step 1 of 3: Welcome". Every dialog's text and buttons are reachable. [U9]
- [ ] **2.8.4** Every panel and dialog, including the quit panel, works by mouse alone, also while the app is not key.
  [U9, B1]

### 2.9 Search isolation

- [ ] **2.9.1** ⌘F opens search only on the surface in front, window or notch; the other surface stays unfiltered. The
  text survives a trip to the details and back. Changing the tab clears it; collapsing the notch and switching
  between demo and live data close it. Activity has its own search ("Search activity"). A project, name, PID or port
  finds its row; no match shows "No matches". [B4]

### 2.10 Motion contract

As `PanelMotion`, `DirectionalStage`, `MonitorPanel` and `NotchController` define it.

- [ ] **2.10.1** Tab switch: the new tab enters over 150 ms with 12 pt of travel from its side of the bar and a 2 pt
  blur; the departing tab leaves over 120 ms.
- [ ] **2.10.2** Push and pop: a page enters over 150 ms with 12 pt of travel and leaves over 120 ms. The list stays
  mounted underneath: it fades out with 6 pt of travel and keeps its scroll position. [B9]
- [ ] **2.10.3** Introduction: a step enters over 240 ms with 32 pt of travel; the previous step leaves over 120 ms
  with half the travel. [U10]
- [ ] **2.10.4** Panel height: 220 ms, only for navigation on the surface in use; scans, typing and the other surface
  resize at once. The width is 480 pt. Content heights: Servers and Agents 168–320 pt by their rows and share rows,
  Actions and Activity 284 pt, details and output 316 pt, Settings 398 pt.
- [ ] **2.10.5** Notch: it expands over 260 ms and collapses over 180 ms; its content fades in over 160 ms and out over
  120 ms. Ears appear after a 200 ms hover.
- [ ] **2.10.6** Dialogs replace the panel body over 180 ms with a 0.98 scale and give it back over 120 ms. Toasts rise
  4 pt over 160 ms and leave over 120 ms. Row hover reveals take 120 ms. Pointer presses scale to 0.96.
- [ ] **2.10.7** Every curve is a cubic ease-out (`timingCurve(0.23, 1, 0.32, 1)` for fades, `(0.25, 1, 0.5, 1)` for
  settles), and no transition exceeds 260 ms, well under 500 ms. Keyboard and accessibility activations switch without
  travel. Rapid reversals keep page identity, and a stale completion never shrinks a newer transition's canvas.
- [ ] **2.10.8** Reduce Motion removes travel, blur, scale and height motion and fades opacity over 100 ms instead.
  `PORTS_MOTION_PREVIEW=slow` on a debug build slows everything tenfold for inspection; `reduced` forces Reduce
  Motion, Reduce Transparency and Increase Contrast. Release builds ignore the variable.
- [ ] **2.10.9** The window and the notch share one presentation coordinator. Inline forms and confirmations replace
  the panel body instead of nesting sheets. Two expanded panels never show at once.

### 2.11 Names, settings and links

- [ ] **2.11.1** Names: the tabs Servers · Agents · Actions (Server · Agenten · Aktionen), the pages Activity
  (Aktivität) and Settings (Einstellungen), and the app's name "Byte Ports" everywhere. [U1, U6]
- [ ] **2.11.2** Settings has the groups DETECTION, ACCESS, TERMINAL and UPDATES, and a footer with Introduction ·
  Demo · Help ↗ · Privacy ↗, then "Byte Ports 1.0.0" and Quit. [U4]
- [ ] **2.11.3** Privacy ↗ resolves: in German to https://ports.byte.de/datenschutz/, whose notice describes the
  opt-in weekly check (5.8, 5.9); in English to https://github.com/Byte-de/ports#privacy-and-sharing (5.10). Help ↗
  opens the README. [U4, P2]
- [ ] **2.11.4** The terminal picker lists Terminal and the installed terminal apps, the others as "(not installed)".
  A CLI agent's details offer "Open in <app>", which opens a new window in the project folder. Check iTerm2, Ghostty
  and Warp as far as they are installed (5.12). [U8]
- [ ] **2.11.5** The introduction has three steps. Welcome shows only the app icon, "Welcome to Byte Ports" and the
  preview headed "Everything at a glance." "Always within reach." offers the Window and Notch panel cards, the notch
  replacing the window, with "Open at login" and "Check for updates weekly" off. "All set." offers View Demo and Open
  Byte Ports. Skip changes no setting; a repeated introduction shows the current choices. [U10]
- [ ] **2.11.6** The docs match the candidate: README (requirements, menu bar only, both languages, privacy with the
  opt-in weekly check, the loopback HTTP check before sharing, the shell environment, the hidden menu bar item and
  detached daemons, the support log command), CHANGELOG 1.0.0, SECURITY and CONTRIBUTING. Before tagging, the
  CHANGELOG heading has no `(unreleased)` marker, as docs/RELEASING.md says. [P7]

## 3. Hardware and session matrix

Each row records the configuration used: Mac model, displays with resolution and scaling, macOS build.

- [ ] **3.1 Multi-display with notch.** A built-in notch plus an external display, and the external display alone
  with the lid closed. Collapsed and expanded, the notch panel stays on the notched screen while focus moves between
  displays, moves to the primary screen with the lid closed, and follows unplugging and replugging. The window keeps a
  position on a connected screen. [B12]
- [ ] **3.2 Compact notch element.** At rest nothing is visible: black on the notch with no black edges around it,
  nothing on a plain screen. After a short hover on the notch, or with keyboard focus, ears show the agent and server
  counts and disappear when the pointer leaves. On a plain screen, the top 4 pt at the centre reveal a black pill with
  both counts inside the menu bar. A click on either expands the panel below the menu bar. Demo mode adds an orange
  dot. With a crowded menu bar whose items reach the notch, a pointer moving along the menu bar does not open the
  ears, every item next to the notch stays clickable, and nothing covers title bars or tabs of other apps. An
  auto-hidden menu bar on a plain screen hides the pill. [U12, B12, B5a]
- [ ] **3.3 Scaling.** The built-in display at Default, More Space and Larger Text; an external display at 1x and at a
  Retina scale. The notch geometry, the pill and the window stay aligned and sharp, and no text is clipped. [B12]
- [ ] **3.4 Full-screen Spaces.** Over a full-screen app no compact element shows. A click on the menu bar item, with
  the menu bar revealed, opens the panel there, and so does ⌃⌥⌘R. [U12]
- [ ] **3.5 Sleep and wake.** With a share active and 2 actions running, `pmset sleepnow`, then wake after at least
  5 minutes. Detection resumes with an immediate scan; both actions still run and are listed once; the share
  reconnects ("Reconnecting…") or ends with a message. After reconnecting, the clipboard is untouched and the link
  stays in its row, with no toast: only the click that started a share hands its link over (2.5.2). Activity shows no
  flood of entries. Correlate with `pmset -g log | grep -E ' (Sleep|Wake) '`. [B5b, E6]
- [ ] **3.6 Lid closed.** In clamshell mode with an external display, the panel and the compact element move to the
  external primary screen; opening the lid brings them back to the notch. [B12]
- [ ] **3.7 Reduce Motion, Reduce Transparency and Increase Contrast** (System Settings › Accessibility › Display),
  each alone and all together, in the window and the notch: Reduce Motion as in 2.10.8; Reduce Transparency replaces
  Liquid Glass with the solid panel surface; Increase Contrast keeps text and controls legible on every page.
- [ ] **3.8 Mac without a notch.** The plain-screen behaviour of 3.2 on real hardware, and the introduction's notch
  card ("Works on Macs without a notch."). Blocked by 5.12. [B12, U12]

## 4. Performance budgets

Release targets. Record the own-process count (`ps -U "$(id -u)" -o pid= | wc -l`) with every run, because scan cost
grows with it, and compare only the same build configuration.

| Id | Budget | Command |
| --- | --- | --- |
| 4.1 | Scan: p95 ≤ 100 ms wall time, 0 ms child CPU per scan | release `ports-diagnostics --benchmark 20` |
| 4.2 | 8 h idle, every surface hidden, notch off: average CPU ≤ 0.5%, Energy Impact ≤ 1.0, RSS growth ≤ 10% | `caffeinate -i Scripts/measure-resources.sh "$(pgrep -x BytePorts)" 28800 60 /tmp/ports-idle.csv` |
| 4.3 | 8 h idle with the compact notch visible: average CPU ≤ 1.0% | as 4.2, with the notch on, to `/tmp/ports-notch.csv` |
| 4.4 | 1 h active: average CPU ≤ 3%, highest 60 s sample ≤ 15%, RSS ≤ 150 MB | `Scripts/measure-resources.sh "$(pgrep -x BytePorts)" 3600 60 /tmp/ports-active.csv` |

```sh
source Scripts/toolchain.sh
swift build "${swift_options[@]}" -c release --product ports-diagnostics
"$(swift build "${swift_options[@]}" -c release --show-bin-path)/ports-diagnostics" --benchmark 20
```

- The 8 h runs need an otherwise idle Mac: displays may sleep, the system may not (`caffeinate -i`).
- The active hour: the window open on Servers, a tab or page change every minute, search used now and then, one
  action printing `while :; do date; sleep 1; done`, one share active, and the default 3 s interval.
- Reading the CSV: the first row is `top`'s reference sample (CPU 0.0), so leave it out. Average CPU is the script's
  `ps`-based summary; Energy Impact is the average of `energy_impact`; RSS growth runs from the first to the last
  `memory` value; the 60 s peak is the highest `cpu_percent` at a 60 s interval. CSVs stay out of the repository;
  record the summaries here.
- Optional cross-checks: `sudo powermetrics --samplers tasks --show-process-energy -i 60000 -n 60`, and Activity
  Monitor › Energy › 12 hr Power.

### Baseline (before E1/E2)

Recorded 26 October 2026, 20:44 CET, with the scanner of commit d393524 (lsof
listener discovery). Host: Apple M2 Max (12 cores, 64 GB), macOS 26.6.2 (25G83),
Swift 6.4; other work kept the load average near 6. Own-process count: 829 processes
of the current user, 26 of them listed as services. Release build of
`ports-diagnostics` (options from `Scripts/toolchain.sh`), one scanner, one
unreported warm-up scan, then `ports-diagnostics --benchmark 20`:

```json
{
  "cpuMillisecondsPerScan" : {
    "children" : 79.4,
    "self" : 43.9
  },
  "maxResidentMegabytes" : 12.5,
  "processes" : 829,
  "scans" : 20,
  "services" : 26,
  "wallMilliseconds" : {
    "max" : 222.4,
    "p50" : 213.2,
    "p95" : 221.1
  }
}
```

Children CPU is the spawned `lsof`. The debug binary that `Scripts/check.sh` builds
measured p95 338.3 ms with 161.6 ms self CPU per scan, so compare the same build
configuration. `Scripts/measure-resources.sh <pid> <seconds> [interval] [out.csv]`
samples the running app without root: CSV rows from `top`, average CPU from `ps`
and the idle wake-up delta.

## 5. External gates

Each gate names its owner and what blocks it today. "Done when" is the evidence that closes it.

| Id | Gate | Owner | Blocker | Done when |
| --- | --- | --- | --- | --- |
| 5.1 | Apple Developer agreement | Christian (maintainer), with the account holder | Apple answers HTTP 403 until the account holder accepts the required agreement | `xcrun notarytool history --keychain-profile BYTE_NOTARY` succeeds |
| 5.2 | Notarization and stapling | Christian (maintainer) | 5.1 | `Scripts/release.sh` completes: app and DMG accepted, stapled and assessed by `spctl`; submission ids recorded |
| 5.3 | Release secrets | Christian (maintainer, repository admin) | The `release` environment lacks the five secrets of docs/RELEASING.md; secrets of another repository can't be read back or copied | The Release workflow passes its signing input checks |
| 5.4 | CI run on the release commit | Christian (maintainer) | Nothing has been pushed, so the Check workflow and its "Smoke-launch app" step have never run on a hosted runner | The Check workflow is green on the release commit and the smoke step printed "Smoke-launched app", not the no-GUI notice; `Scripts/release.sh` requires the launch, so the Release workflow fails on a runner without a GUI login session |
| 5.5 | Bundled cloudflared workflow | Christian (maintainer) | Needs the pushed repository, then `gh workflow run cloudflared.yml` | The workflow is green for the pinned version |
| 5.6 | Quarantined install on a second Mac | Christian (maintainer) | 5.2, and a second Mac with a clean user account | A browser download of Byte-Ports.dmg, dragged to Applications, passes Gatekeeper on first launch; no security setting or quarantine attribute is changed |
| 5.7 | 8 h energy traces (4.2, 4.3) | Christian (maintainer) | Needs an otherwise idle Mac for two 8 h runs | Both summaries recorded in §6 |
| 5.8 | Website deployment and domain | Christian (maintainer), with the Vercel owner | Assigning ports.byte.de returned HTTP 403; redeploying from the private repository fails Vercel's Git-author/team association check; DNS is managed outside Vercel | https://ports.byte.de serves the final source; `released: true` is set only once the download and the tap resolve |
| 5.9 | Website privacy notice | Christian (maintainer), with the website session (EXT-WEB) | Waits for the EXT-WEB update and 5.8 | The Datenschutz page describes the opt-in weekly update check (off by default, no identifiers, only the time and result of the last check stored on the Mac), the shell environment read on the Mac and the loopback HTTP check before sharing |
| 5.10 | English privacy link | Christian (maintainer) | The README anchor opens for everyone only once Byte-de/ports is public; there is no English website page yet | https://github.com/Byte-de/ports#privacy-and-sharing opens the section without signing in |
| 5.11 | Homebrew cask | Christian (maintainer, tap maintainer) | Follows publishing; `Scripts/prepare-homebrew.sh` rejects an unnotarized DMG (5.2) | The cask PR to Byte-de/homebrew-tap is merged and `brew install --cask byte-de/tap/byte-ports` installs 1.0.0 |
| 5.12 | Other hardware | Christian (maintainer) | Needs a Mac without a notch, an external display, and iTerm2, Ghostty and Warp installed | 3.1, 3.3, 3.8 and 2.11.4 recorded on that hardware |
| 5.13 | Copy review | Christian (maintainer), with a native-level English reviewer | Reviewer availability | The user reviewed the German and the reviewer the English from `Scripts/check-localization.sh --report`, and the fixes landed |
| 5.14 | Published release | Christian (maintainer) | 5.1–5.4 and every local gate | Tag `v1.0.0` on the release commit; Byte-Ports.dmg published with the CHANGELOG notes; SHA256SUMS matches; the app's Check Now says "Byte Ports is up to date." |

## 6. Sign-off

| Gate | Owner | Status | Evidence | Date |
| --- | --- | --- | --- | --- |
| 1.1 Static checks | Christian (maintainer) | pass | `Scripts/release.sh` ran `Scripts/lint.sh` first on `fb67d27` | 30 Oct 2026 |
| 1.2 Tests and checks | Christian (maintainer) | pass | `Scripts/check.sh` inside `Scripts/release.sh`: PortsCoreTests 208 tests in 25 suites, PortsFeaturesTests 86 tests in 12 suites, supervisor, integration, listener parity and localization (342 keys) passed | 30 Oct 2026 |
| 1.3 Bundle contract | Christian (maintainer) | pass | `Scripts/validate-bundle.sh` on the Developer ID release bundle after the build and again after stapling (`Scripts/release.sh`) | 30 Oct 2026 |
| 1.4 Smoke launch | Christian (maintainer) | pass | `Scripts/smoke-app.sh` on the signed release bundle before notarization (`Scripts/release.sh`); the app copied out of the mounted DMG also ran 6 s with `--demo` and an empty state directory without faults | 30 Oct 2026 |
| 1.5 CI on the release commit | Christian (maintainer) | pass | Check run 41041844147 on `main` 1369300 (hosted macos-26 arm64): lint, 208 + 86 tests, supervisor and integration, release build, bundle validation, and "Smoke-launched app" (the runner has a GUI session, so `Scripts/release.sh` can smoke-launch in the Release workflow) | 30 Oct 2026 |
| 1.6 Bundled cloudflared | Christian (maintainer) | blocked: 5.5 | | |
| 1.7 Live tunnel | Christian (maintainer) | pass | `ports-diagnostics --tunnel-integration` with the bundled cloudflared 2026.10.5 and again with 2026.10.6: PASS (real client, connected status, public HTTPS fixture, share revoked, local server preserved, cleanup). The public request now retries for 90 s, because Tailscale's MagicDNS on this host first cached the new hostname as missing; a fetch through 1.1.1.1 returned HTTP 200 right away | 30 Oct 2026 |
| 2.1 Menu bar app and login launch | Christian (maintainer) | open | | |
| 2.2 Both languages | Christian (maintainer) | open | | |
| 2.3 Discovery and navigation | Christian (maintainer) | open | | |
| 2.4 Launch and quit | Christian (maintainer) | open | | |
| 2.5 Sharing | Christian (maintainer) | open | | |
| 2.6 Updates | Christian (maintainer) | open | | |
| 2.7 Logging and redaction | Christian (maintainer) | open | | |
| 2.8 Keyboard and accessibility | Christian (maintainer) | open | | |
| 2.9 Search isolation | Christian (maintainer) | open | | |
| 2.10 Motion contract | Christian (maintainer) | open | | |
| 2.11 Names, settings and links | Christian (maintainer) | open (2.11.3 waits for 5.8–5.10) | | |
| 3.1 Multi-display with notch | Christian (maintainer) | open | | |
| 3.2 Compact notch element | Christian (maintainer) | open | | |
| 3.3 Scaling | Christian (maintainer) | open | | |
| 3.4 Full-screen Spaces | Christian (maintainer) | open | | |
| 3.5 Sleep and wake | Christian (maintainer) | open | | |
| 3.6 Lid closed | Christian (maintainer) | open | | |
| 3.7 Reduce Motion, Transparency and Contrast | Christian (maintainer) | open | | |
| 3.8 Mac without a notch | Christian (maintainer) | blocked: 5.12 | | |
| 4.1 Scan benchmark | Christian (maintainer) | open | | |
| 4.2 8 h idle, notch off | Christian (maintainer) | blocked: 5.7 | | |
| 4.3 8 h idle, compact notch | Christian (maintainer) | blocked: 5.7 | | |
| 4.4 1 h active | Christian (maintainer) | open | | |
| 5.1 Apple Developer agreement | Christian (maintainer) | pass | `xcrun notarytool store-credentials BYTE_NOTARY` validated the App Store Connect API key; submissions were accepted | 30 Oct 2026 |
| 5.2 Notarization and stapling | Christian (maintainer) | pass | `Scripts/release.sh /tmp/ports-release` exit 0: app `6e5ba454-4e9d-4e5e-837b-640a7f1b8c56` and DMG `fe0093ee-381e-4024-bf3c-ce17beb13468` Accepted, both stapled and validated, `spctl` accepted both as "Notarized Developer ID". The DMG mounted read-only, its app copied to an empty folder passed `codesign --verify --deep --strict`, `spctl --assess --type execute` and `stapler validate`, version 1.0.0 (3). SHA-256 of Byte-Ports.dmg: `5c937606d72bc31cd5d941d05bd50e3ec70ef2efabee0b153880e1041c588d38` | 30 Oct 2026 |
| 5.3 Release secrets | Christian (maintainer) | blocked: secrets missing | | |
| 5.4 CI run on the release commit | Christian (maintainer) | pass | See 1.5; the repository is now Byte-de/ports (renamed from Byte-de/relay, which redirects) | 30 Oct 2026 |
| 5.5 Bundled cloudflared workflow | Christian (maintainer) | blocked: not pushed | | |
| 5.6 Quarantined install on a second Mac | Christian (maintainer) | blocked: second Mac | | |
| 5.7 8 h energy traces | Christian (maintainer) | blocked: idle Mac for 16 h | | |
| 5.8 Website deployment and domain | Christian (maintainer) | blocked: Vercel HTTP 403 | | |
| 5.9 Website privacy notice | Christian (maintainer) | blocked: EXT-WEB, 5.8 | | |
| 5.10 English privacy link | Christian (maintainer) | blocked: repository private | | |
| 5.11 Homebrew cask | Christian (maintainer) | blocked: release | | |
| 5.12 Other hardware | Christian (maintainer) | blocked: hardware | | |
| 5.13 Copy review | Christian (maintainer) | blocked: reviewer | | |
| 5.14 Published release | Christian (maintainer) | blocked: 5.3, 5.4 | | |

## Finding map

Where each review finding is checked. Findings without a visible effect map to automated gates and budgets.

| Finding | Checklist lines |
| --- | --- |
| B1 | 2.1.9, 2.4.3–2.4.6, 2.4.12–2.4.16, 2.8.4 |
| B2 | 2.4.2, 2.4.5 |
| B3 | 2.3.5 |
| B4 | 2.9.1 |
| B5a | 2.5.3, 2.5.8, 3.2 |
| B5b | 2.5.2, 3.5 |
| B5c | 1.7, 2.5.1, 2.5.4, 2.5.5 |
| B6 | 2.3.8 |
| B7 | 2.3.4 |
| B8 | 2.3.2, 2.3.3 |
| B9 | 2.3.1, 2.3.6, 2.10.2 |
| B10 | 2.4.8 |
| B11 | 2.4.1 |
| B12 | 3.1, 3.2, 3.3, 3.6, 3.8 |
| B13a | 2.3.4 |
| B13b | 2.3.6 |
| B13c | 2.3.1, 2.8.1 |
| B13d | 2.5.1 |
| B14 | 1.2 (`RefreshCoalescerTests`), 2.3.9 |
| B15 | 2.3.7, 2.5.6 |
| B16 | 2.3.8 |
| B17 | 2.3.11, 2.3.12 |
| B18 | 2.5.7 |
| B19 | 2.3.12 |
| E1 | 2.3.13, 4.1 |
| E2 | 1.2 (listener parity), 4.1 |
| E3 | 2.4.3, 2.4.8 |
| E4 | 1.2, 4.1 |
| E5 | 2.5.3, 2.5.9 |
| E6 | 2.3.13, 2.7.3, 3.5, 4.2, 4.3 |
| E7 | 1.2, 2.3.13, 4.1 |
| E8 | 2.4.8, 4.4 |
| E9 | 1.2, 2.6.5 |
| U1 | 2.3.1, 2.3.2, 2.11.1 |
| U2 | 2.3.8 |
| U3 | 2.3.10, 2.4.7, 2.4.11, 2.8.2 |
| U4 | 2.11.2, 2.11.3 |
| U5 | 2.3.10, 2.4.1, 2.5.1, 2.5.6 |
| U6 | 2.2.3, 2.11.1, 5.13 |
| U7 | 2.4.9 |
| U8 | 2.11.4 |
| U9 | 2.1.1–2.1.11, 2.4.15, 2.8.1, 2.8.3, 2.8.4 |
| U10 | 2.1.2, 2.6.1, 2.10.3, 2.11.5 |
| U11 | 2.4.10 |
| U12 | 2.1.6, 2.8.2, 3.2, 3.4, 3.8 |
| P1 | 2.1.8 |
| P2 | 2.6.1–2.6.5, 2.11.3, 5.9 |
| P3 | 1.1, 2.7.1–2.7.3 |
| P4 | 1.2 |
| P5 | 1.2, 2.2.1–2.2.4 |
| P6 | §1, §4, §5, §6 |
| P7 | 2.11.6 |
| P8 | 1.3, 1.4, 2.1.1, 2.2.1 |

## Build 2 (archived)

Recorded for 1.0.0 build 2, up to 1 October 2026, and kept for reference. None of it counts for build 3.
Test host: Apple Silicon, macOS 26.6.2. Swift 6.4, macOS 26.5 SDK.

- Branding refresh, 1 October 2026 (1.0.0 build 2): the app icon uses the supplied
  Byte B SVG without geometry changes, drawn in 84% white on `#66BFFF`. Strict
  formatting, the release build, Developer ID signatures, DMG integrity and the
  mounted app's signature, build number and icon bytes were verified. Application
  behaviour is unchanged from the checks below.
- 68 Swift tests in 11 suites: listener parsing, classification, process identity
  and ownership, launch lifecycle, preferences, migration, tunnel state, panel
  presentation, directional transitions and height interpolation.
- 4 dedicated C supervisor checks: control-pipe EOF, unresponsive child,
  supervisor termination and parent crash cleanup.
- Disposable local service integration: TCP discovery, identity verification,
  pause, resume, log capture, restart, graceful stop and cleanup.
- Live Cloudflare smoke test with the bundled signed client and supervisor: a
  temporary localhost server returned its fixed test text through the generated
  public HTTPS URL. Closing the owner pipe stopped the tunnel. No user project
  or file was exposed by this test.
- Update metadata tests: numeric semantic versions, no downgrade, invalid versions,
  draft/prerelease rejection, malformed/oversized response and untrusted URL rejection.
- Migration preserves the prototype file, retains user settings, rejects malformed
  data and gives existing Ports preferences precedence. Sharing consent defaults off.
- A 30-second foreground sample (15 measurements) averaged 2.37% app-process CPU,
  peaked at 13.8%, and reached 137.1 MB RSS. This is a short functional sample,
  not an energy benchmark; spawned scanner tools are not included.
- Strict Swift formatting; release app and bundled helpers signed with Developer ID
  and Hardened Runtime. Recursive code-signature verification passes.
- GitHub macOS 26 CI passes tests, process integration, strict formatting, the
  release build and bundle verification (run 36891313075, commit a7812b5).
- The signed local candidate DMG passes its integrity check. Its app passes
  recursive signature verification both when mounted read-only and after copying
  to an empty installation test directory. Gatekeeper correctly identifies it as
  an unnotarized Developer ID build; it is not a public release artifact.
- Native UI: all onboarding steps forward/backward, completion, blue accent,
  1.0.0 version, server/project/settings navigation, public-sharing notice and cancel,
  no-release/network-error handling for manual updates.
- Website: production static export, TypeScript and ESLint, responsive desktop/mobile
  rendering, accessible tab controls and static FAQs. Updated runtime dependencies
  pass the production dependency audit with zero known vulnerabilities.
