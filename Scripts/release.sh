#!/bin/bash
# Fail-closed public distribution. No unsigned or unnotarized artifact is copied out.
set -euo pipefail
source "$(dirname "$0")/toolchain.sh"
: "${SIGN_IDENTITY:?Set SIGN_IDENTITY to your Developer ID Application identity}"
[[ "$SIGN_IDENTITY" != "-" ]] || { echo 'Public releases require Developer ID signing.' >&2; exit 1; }
[[ "$(uname -m)" == arm64 ]] || { echo 'This release supports Apple Silicon only.' >&2; exit 1; }
notary_profile="${NOTARY_PROFILE:-BYTE_NOTARY}"
release_output="${1:-$project_root/dist}"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$project_root/Resources/Info.plist")
# Verify credentials/agreements before a potentially long build.
/usr/bin/xcrun notarytool history --keychain-profile "$notary_profile" --output-format json >/dev/null
[[ ! -e "$release_output/Byte-Ports.dmg" ]] || { echo 'Release output already exists; choose an empty destination.' >&2; exit 1; }
"$project_root/Scripts/check.sh"
release_stage=$(mktemp -d "$build_directory/release.XXXXXX")
trap 'rm -rf "$release_stage"' EXIT
export PORTS_CONFIGURATION=release
"$project_root/Scripts/build-app.sh" "$release_stage/Byte Ports.app"
app="$release_stage/Byte Ports.app"
/usr/bin/ditto -c -k --norsrc --keepParent "$app" "$release_stage/notary.zip"
notarize() {
  local target="$1" receipt="$2"
  /usr/bin/xcrun notarytool submit "$target" --keychain-profile "$notary_profile" --wait --output-format json > "$receipt"
  python3 - "$receipt" <<'PY'
import json,sys
result=json.load(open(sys.argv[1]))
if result.get('status') != 'Accepted':
    raise SystemExit('Apple did not accept this submission: '+str(result.get('id','unknown')))
PY
}
notarize "$release_stage/notary.zip" "$release_stage/app-notary.json"
/usr/bin/xcrun stapler staple "$app"
/usr/bin/xcrun stapler validate "$app"
/usr/bin/codesign --verify --deep --strict "$app"
/usr/sbin/spctl --assess --type execute --verbose=2 "$app"
mkdir "$release_stage/volume"
/usr/bin/ditto --norsrc "$app" "$release_stage/volume/Byte Ports.app"
ln -s /Applications "$release_stage/volume/Applications"
/usr/bin/hdiutil create -volname 'Byte Ports' -srcfolder "$release_stage/volume" -ov -format UDZO "$release_stage/Byte-Ports.dmg"
/usr/bin/codesign --force --timestamp --sign "$SIGN_IDENTITY" "$release_stage/Byte-Ports.dmg"
notarize "$release_stage/Byte-Ports.dmg" "$release_stage/dmg-notary.json"
/usr/bin/xcrun stapler staple "$release_stage/Byte-Ports.dmg"
/usr/bin/xcrun stapler validate "$release_stage/Byte-Ports.dmg"
/usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=2 "$release_stage/Byte-Ports.dmg"
mkdir -p "$release_output"
cp "$release_stage/Byte-Ports.dmg" "$release_output/Byte-Ports.dmg"
cp "$release_stage/app-notary.json" "$release_stage/dmg-notary.json" "$release_output/"
(cd "$release_output" && /usr/bin/shasum -a 256 Byte-Ports.dmg > SHA256SUMS)
printf 'Verified Byte Ports %s: %s/Byte-Ports.dmg\n' "$version" "$release_output"
