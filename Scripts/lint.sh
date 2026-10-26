#!/bin/bash
# Fast static checks without a build. CI runs this before Scripts/check.sh.
set -euo pipefail
source "$(dirname "$0")/toolchain.sh"
formatter="${DEVELOPER_DIR:-}/usr/bin/swift-format"
# Full Xcode keeps swift-format inside its toolchain rather than in usr/bin.
[[ -x "$formatter" ]] || formatter="$(/usr/bin/xcrun --find swift-format)"
cd "$project_root"
"$formatter" lint --strict --recursive Sources Tests Package.swift
python3 -I Scripts/check-log-privacy.py --self-test
python3 -I Scripts/check-log-privacy.py Sources
