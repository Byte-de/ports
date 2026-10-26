#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/toolchain.sh"
/usr/bin/swift test "${swift_options[@]}"
/usr/bin/swift build "${swift_options[@]}" --product ports-diagnostics
/usr/bin/swift build "${swift_options[@]}" --product ports-tunnel-runner
binary_directory="$(/usr/bin/swift build "${swift_options[@]}" --show-bin-path)"
python3 "$project_root/Scripts/test-tunnel-runner.py" "$binary_directory/ports-tunnel-runner"
"$binary_directory/ports-diagnostics" --integration
"$binary_directory/ports-diagnostics"
