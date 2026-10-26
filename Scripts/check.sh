#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/toolchain.sh"
/usr/bin/swift build "${swift_options[@]}" --build-tests
# One run per test target, so each module reports its own result.
for directory in "$project_root"/Tests/*/; do
  target="$(basename "$directory")"
  echo "Testing $target"
  /usr/bin/swift test "${swift_options[@]}" --skip-build --filter "^$target\."
done
/usr/bin/swift build "${swift_options[@]}" --product ports-diagnostics
/usr/bin/swift build "${swift_options[@]}" --product ports-tunnel-runner
binary_directory="$(/usr/bin/swift build "${swift_options[@]}" --show-bin-path)"
python3 "$project_root/Scripts/test-tunnel-runner.py" "$binary_directory/ports-tunnel-runner"
"$binary_directory/ports-diagnostics" --integration
"$binary_directory/ports-diagnostics"
"$binary_directory/ports-diagnostics" --benchmark 3 >/dev/null
python3 -I "$project_root/Scripts/check-localization.py" --self-test
"$project_root/Scripts/check-localization.sh"
