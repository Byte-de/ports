# Release verification — 1.0.0

Test host: Apple Silicon, macOS 26.6.2. Swift 6.4, macOS 26.5 SDK.
Only evidence from completed checks is listed as passed. Other-machine coverage
is a release follow-up, not an inferred result.

## Completed

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

## Performance baseline (before E1/E2)

Recorded 26 October 2026, 20:44 CET, with the scanner of commit d393524 (lsof
listener discovery). Host: Apple M2 Max (12 cores, 64 GB), macOS 26.6.2 (25G83),
Swift 6.4; other work kept the load average near 6. Own-process count: 829 processes
of the current user, 26 of them listed as services. Release build of
`ports-diagnostics` (options from `Scripts/toolchain.sh`), one scanner, one
unreported warm-up scan, then `ports-diagnostics --benchmark 20`:

```sh
source Scripts/toolchain.sh
swift build "${swift_options[@]}" -c release --product ports-diagnostics
"$(swift build "${swift_options[@]}" -c release --show-bin-path)/ports-diagnostics" --benchmark 20
```

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
and the idle wake-up delta. The first CSV row is `top`'s reference sample (CPU 0.0);
leave it out of averages. App traces are recorded with the release checks.

## Distribution gates still requiring external access

- Apple notarization/stapling and Gatekeeper acceptance are blocked by Apple's
  HTTP 403 agreement response. The account holder must accept the required agreement.
- A quarantined browser download and drag-to-Applications installation must be
  checked after notarization. No security settings or quarantine attributes are removed.
- Release CI needs the signing/notary secrets described in RELEASING.md. Existing
  secrets in another repository cannot be read back or implicitly copied.
- The custom website domain requires Vercel authorization; the project exists but
  domain assignment returned HTTP 403. DNS is managed outside Vercel.
- The initial Vercel preview is reachable. A later deployment from the private
  Git repository is blocked by Vercel's Git-author/team association check. Complete
  that association through the account owner before redeploying the final source.

## Pending manual checks

Added with the changes they cover; the release checklist takes them over.

- Share link: the first and every later share copies its link as soon as it
  is ready, toast “Share link copied”, also when something else was copied in
  between; only a link that comes up more than 60 s after the click (after a
  sleep) is offered in its row instead.
- Quit agents: every agent row reveals a red power button (“Quit…”), also for
  apps such as Claude and CLIs inside app bundles. The confirmation says that an
  app quits as with ⌘Q, or that the host app (such as ChatGPT) may start its CLI
  again. Claude receives a normal quit request; a CLI agent receives SIGTERM. A
  paused CLI agent quits too. Apps still offer no pause.
- Sharing indicator: the menu bar icon turns into a globe within 0.5 s of a
  share starting and returns to the port glyph once the last share has stopped.
  VoiceOver reads “Byte Ports – public share active, <count>”, otherwise
  “Byte Ports, <count>”. The compact notch shows an accent globe after the
  counts, and VoiceOver reads “Open Byte Ports, public share active”. Demo mode
  shows neither.
- One panel: with the notch on, a click on the menu bar item expands the notch
  panel with squircle corners and a second click collapses it; no other window
  appears. With the notch off, the click shows the floating squircle window;
  after moving it, closing it (⌘W or a click on the item) and quitting, it comes
  back at the same position; the first time it is centred on the screen with
  the menu bar item. Right-click and Control-click show Open, Settings… and
  Quit. ⌘, and Settings… open settings in the panel at home. No white frame in
  light or dark appearance. VO-Space on the item toggles the panel.
  `--onboarding` runs in the window and, with the notch chosen, hands over to
  the notch.
- With the Ports item hidden in System Settings › Menu Bar, the globe is hidden
  too, as the README states; the service row and the notch still show the share.

## Hardware and session follow-up

The supported minimum system is declared, not a claim to have tested every 26.x
release. Before widening distribution, use another Mac for a clean installation
and a second hardware configuration. Exercise display attach/detach, different
scaling factors, full-screen Spaces, sleep/wake and long idle/active sessions.
Real hardware cycles and a long energy trace have not been performed in this
shared interactive session. Keep those gaps visible in release decisions.

## Motion and presentation contracts

Tab entry/exit: 150/120 ms. Onboarding entry/exit: 240/120 ms. Panel resize: 220 ms.
All normal transitions stay under 500 ms, with cubic ease-out curves. New pages
enter from the opposite edge to the departing page. Rapid reversals preserve
identity and cancel stale cleanup. Reduce Motion removes spatial/blur/height motion
and uses a short opacity change. Only the active presentation surface resizes.

The window and the notch share presentation coordination. Inline forms and
confirmations replace the panel body instead of adding nested borderless sheets.
A compact notch may coexist with a full panel; two expanded panels must not.
