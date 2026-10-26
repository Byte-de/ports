#!/bin/bash
# Sourced by build/check scripts. No global Xcode selection is modified.
set -euo pipefail
if [[ -z "${DEVELOPER_DIR:-}" && "${GITHUB_ACTIONS:-}" == "true" ]]; then
  # Hosted runners provide Swift Testing with the selected full Xcode toolchain.
  # Their separate CLT installation may omit that module.
  export DEVELOPER_DIR="$(/usr/bin/xcode-select -p)"
elif [[ -z "${DEVELOPER_DIR:-}" && -d /Library/Developer/CommandLineTools ]]; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi
if [[ -n "${PORTS_SDK:-}" ]]; then
  sdk_path="$PORTS_SDK"
elif [[ "${DEVELOPER_DIR:-}" == */CommandLineTools && -d "$DEVELOPER_DIR/SDKs/MacOSX26.5.sdk" ]]; then
  # Some CLT previews ship an SDK 27 State macro without the SwiftUI macro plugin.
  # The stable SDK uses property wrappers and supports our macOS 26 deployment target.
  sdk_path="$DEVELOPER_DIR/SDKs/MacOSX26.5.sdk"
else
  sdk_path="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
fi
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Keep generated bundles out of cloud-synced source folders: Finder metadata on
# .xctest bundles can otherwise invalidate Apple's code-signing step.
build_directory="${PORTS_BUILD_DIR:-${TMPDIR:-/tmp}/ports-build-$(id -u)}"
mkdir -p "$build_directory"
export CLANG_MODULE_CACHE_PATH="$build_directory/module-cache"
swift_options=(--disable-sandbox --sdk "$sdk_path" --package-path "$project_root" --scratch-path "$build_directory"
  --cache-path "$build_directory/cache" --config-path "$build_directory/config" --security-path "$build_directory/security")
if [[ "${DEVELOPER_DIR:-}" == */CommandLineTools ]]; then
  # CLT's SwiftBuild currently omits the Testing macro plugin search path.
  if [[ -d "$DEVELOPER_DIR/usr/lib/swift/host/plugins/testing" ]]; then
    swift_options+=(-Xswiftc -plugin-path -Xswiftc "$DEVELOPER_DIR/usr/lib/swift/host/plugins/testing")
  fi
fi
