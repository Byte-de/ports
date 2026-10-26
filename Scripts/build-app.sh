#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/toolchain.sh"
configuration="${PORTS_CONFIGURATION:-release}"
destination_bundle="${1:-$build_directory/Byte Ports.app}"
/usr/bin/swift build "${swift_options[@]}" -c "$configuration" --product BytePorts
/usr/bin/swift build "${swift_options[@]}" -c "$configuration" --product ports-tunnel-runner
binary_directory="$(/usr/bin/swift build "${swift_options[@]}" -c "$configuration" --show-bin-path)"
"$project_root/Scripts/package-app.sh" "$binary_directory/BytePorts" "$destination_bundle"
