#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/toolchain.sh"
binary="${1:?Pass the compiled BytePorts executable}"
destination_bundle="${2:-$build_directory/Byte Ports.app}"
bundle="$build_directory/AppBundle/Byte Ports.app"
[[ -x "$binary" ]] || { printf 'Executable missing: %s\n' "$binary" >&2; exit 1; }
# Only generated staging content is removed; never touch an installed app or user data.
rm -rf "$build_directory/AppBundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources/ThirdParty" "$bundle/Contents/Helpers"
cp "$binary" "$bundle/Contents/MacOS/BytePorts"
cp "$project_root/Resources/Info.plist" "$bundle/Contents/Info.plist"
cp "$project_root/Resources/BytePorts.icns" "$bundle/Contents/Resources/BytePorts.icns"
cloudflared=$("$project_root/Scripts/fetch-cloudflared.sh")
cp "$cloudflared" "$bundle/Contents/Helpers/cloudflared"
cp "$(dirname "$binary")/ports-tunnel-runner" "$bundle/Contents/Helpers/ports-tunnel-runner"
cp "$project_root/Resources/ThirdParty/"* "$bundle/Contents/Resources/ThirdParty/"
identity="${SIGN_IDENTITY:--}"
sign_args=(--force --sign "$identity")
if [[ "$identity" != "-" ]]; then sign_args+=(--options runtime --timestamp); fi
/usr/bin/codesign "${sign_args[@]}" "$bundle/Contents/Helpers/cloudflared"
/usr/bin/codesign "${sign_args[@]}" "$bundle/Contents/Helpers/ports-tunnel-runner"
# Cosmetic metadata only. Never remove quarantine or change system security settings.
/usr/bin/xattr -d com.apple.FinderInfo "$bundle" 2>/dev/null || true
/usr/bin/xattr -d com.apple.ResourceFork "$bundle" 2>/dev/null || true
/usr/bin/codesign "${sign_args[@]}" "$bundle"
/usr/bin/codesign --verify --deep --strict "$bundle"
[[ ! -e "$destination_bundle" ]] || { printf 'Destination already exists: %s\n' "$destination_bundle" >&2; exit 1; }
/usr/bin/ditto --norsrc "$bundle" "$destination_bundle"
printf 'Built app: %s\n' "$destination_bundle"
