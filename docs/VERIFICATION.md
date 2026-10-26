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

The window, menu and notch share presentation coordination. Inline forms and
confirmations replace the panel body instead of adding nested borderless sheets.
A compact notch may coexist with a full panel; two expanded panels must not.
