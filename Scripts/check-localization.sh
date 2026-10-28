#!/bin/bash
# Missing-translation check in strict mode: compiler-extracted keys against Resources/Localization, with no baseline
# and no German text in Swift literals (docs/LOCALIZATION.md). Extra arguments, e.g. --report, go to the checker.
set -euo pipefail
# Keys are emitted only for recompiled files, so the scan uses its own clean build. The directory is chosen
# before toolchain.sh derives the scratch, cache and module paths from it.
scan_dir="${PORTS_BUILD_DIR:-${TMPDIR:-/tmp}/ports-build-$(id -u)}/localization"
rm -rf "$scan_dir"
export PORTS_BUILD_DIR="$scan_dir"
source "$(dirname "$0")/toolchain.sh"
/usr/bin/swift build "${swift_options[@]}" --product BytePorts -Xswiftc -emit-localized-strings \
  -Xswiftc -emit-localized-strings-path -Xswiftc "$scan_dir/stringsdata" >&2
sources=()
for target in PortsApp PortsCore PortsFeatures; do
  if [[ -d "$project_root/Sources/$target" ]]; then sources+=("$project_root/Sources/$target"); fi
done
# The deleted baseline's path stays, so the check fails if the file ever comes back (E12). It is never read.
python3 -I "$project_root/Scripts/check-localization.py" --stringsdata "$scan_dir/stringsdata" \
  --sources "${sources[@]}" --localizations "$project_root/Resources/Localization" \
  --info-plist "$project_root/Resources/Info.plist" --baseline "$project_root/Scripts/localization-baseline.txt" "$@"
