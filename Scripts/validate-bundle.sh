#!/bin/bash
# Bundle contract shared by CI and release builds. Read-only: never modifies the bundle.
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="${1:?Pass the Byte Ports.app bundle to validate}"
info="$app/Contents/Info.plist"
fail() { printf 'Invalid bundle %s: %s\n' "$app" "$1" >&2; exit 1; }
[[ -f "$info" ]] || fail 'Contents/Info.plist is missing'
/usr/bin/codesign --verify --deep --strict "$app"
/usr/bin/plutil -lint -s "$info" || fail 'Contents/Info.plist does not parse'
for key in CFBundleIdentifier CFBundleShortVersionString CFBundleVersion; do
  expected=$(/usr/bin/plutil -extract "$key" raw -o - "$project_root/Resources/Info.plist")
  actual=$(/usr/bin/plutil -extract "$key" raw -o - "$info" 2>/dev/null) || fail "$key is missing"
  [[ "$actual" == "$expected" ]] || fail "$key is '$actual', expected '$expected'"
done
# One log predicate on the bundle id must cover every PortsLog event.
identifier=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$info")
grep -qF "subsystem = \"$identifier\"" "$project_root/Sources/PortsCore/PortsLog.swift" ||
  fail "PortsLog.subsystem differs from CFBundleIdentifier $identifier"
for helper in cloudflared ports-tunnel-runner; do
  [[ -x "$app/Contents/Helpers/$helper" ]] || fail "Contents/Helpers/$helper is missing or not executable"
  /usr/bin/codesign --verify --strict "$app/Contents/Helpers/$helper"
done
[[ -f "$app/Contents/Resources/ThirdParty/cloudflared-LICENSE.txt" ]] || fail 'cloudflared licence is missing'
# English is the source language in code; German comes from the packaged tables.
for table in de.lproj/Localizable.strings de.lproj/Localizable.stringsdict en.lproj/Localizable.stringsdict; do
  [[ -f "$app/Contents/Resources/$table" ]] || fail "Contents/Resources/$table is missing"
  /usr/bin/plutil -lint -s "$app/Contents/Resources/$table" || fail "Contents/Resources/$table does not parse"
done
region=$(/usr/bin/plutil -extract CFBundleDevelopmentRegion raw -o - "$info" 2>/dev/null) || region=''
[[ "$region" == en ]] || fail "CFBundleDevelopmentRegion is '$region', expected 'en'"
localizations=$(/usr/bin/plutil -extract CFBundleLocalizations json -o - "$info" 2>/dev/null) || localizations=''
for language in en de; do
  [[ "$localizations" == *"\"$language\""* ]] || fail "CFBundleLocalizations does not contain $language"
done
printf 'Validated bundle: %s\n' "$app"
