# Contributing

Small, focused changes are welcome. Open an issue describing a reproducible
problem or a concrete improvement before starting a large feature.

1. Use macOS 26+, Apple Silicon and a Swift 6 toolchain.
2. Run `Scripts/lint.sh` (strict swift-format and the log-privacy guard) and
   `Scripts/check.sh`.
3. Test the affected interaction with an isolated `--state-directory`, in both
   languages: start the built app's executable with `-AppleLanguages '(en)'` and
   `-AppleLanguages '(de)'`.
4. Update the changelog and documentation when user-visible behaviour changes.

Keep process and tunnel logic in PortsCore. Never act on PID alone: preserve the
process start identity and owner checks. Tests may stop only processes they
created. Do not make tests depend on a real user's services or public tunnels.

UI-free app policy, such as lists, navigation, flows and schedules, belongs in
PortsFeatures with unit tests in `Tests/PortsFeaturesTests`. PortsFeatures never
imports AppKit or SwiftUI and returns semantic values, never display text;
PortsApp turns them into views and copy.

Logging: use the `PortsLog` categories and give every interpolation an explicit
`privacy:` argument. Paths, commands, project names, URLs and error descriptions
are private; counts, PIDs, ports, states and codes are public. Never log
environment values, external arguments, service output or search text. Do not
use `print`, `NSLog`, `os_log` or a new `Logger`; `Scripts/lint.sh` enforces
these rules.

Localization: write new or changed user-facing text in English in a localizable
API and add its German translation to `Resources/Localization` in the same
commit. `Scripts/check.sh` fails on missing translations. See
[docs/LOCALIZATION.md](docs/LOCALIZATION.md) for the rules, plural templates and
glossary.

UI changes must preserve one active full panel, keyboard access, quick action
labels and Reduce Motion/Reduce Transparency behaviour. Motion must remain
interruptible and shorter than 500 ms. Avoid introducing sheets into the borderless
panel; use its existing dialog coordination.

Do not commit generated apps, DMGs, caches, recordings, temporary diagnostics,
credentials or private project data. Commercial website font files belong to the
separate private website repository and are not part of this source distribution.
