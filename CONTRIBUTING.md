# Contributing

Small, focused changes are welcome. Open an issue describing a reproducible
problem or a concrete improvement before starting a large feature.

1. Use macOS 26+, Apple Silicon and a Swift 6 toolchain.
2. Run `Scripts/check.sh` and `swift-format lint --strict --recursive Sources Tests Package.swift`.
3. Test the affected interaction with an isolated `--state-directory`.
4. Update the changelog and documentation when user-visible behaviour changes.

Keep process and tunnel logic in PortsCore. Never act on PID alone: preserve the
process start identity and owner checks. Tests may stop only processes they
created. Do not make tests depend on a real user's services or public tunnels.

UI changes must preserve one active full panel, keyboard access, quick action
labels and Reduce Motion/Reduce Transparency behaviour. Motion must remain
interruptible and shorter than 500 ms. Avoid introducing sheets into the borderless
panel; use its existing dialog coordination.

Do not commit generated apps, DMGs, caches, recordings, temporary diagnostics,
credentials or private project data. Commercial website font files belong to the
separate private website repository and are not part of this source distribution.
