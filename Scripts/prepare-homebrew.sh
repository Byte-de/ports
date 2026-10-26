#!/bin/bash
# Generate a cask only from the final stapled, Gatekeeper-accepted DMG.
set -euo pipefail
source "$(dirname "$0")/toolchain.sh"
dmg="${1:?Pass the notarized Byte-Ports.dmg}"
output="${2:?Pass the output path for byte-ports.rb}"
/usr/bin/xcrun stapler validate "$dmg" >/dev/null
/usr/sbin/spctl --assess --type open --context context:primary-signature "$dmg"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$project_root/Resources/Info.plist")
checksum=$(/usr/bin/shasum -a 256 "$dmg" | awk '{print $1}')
cat > "$output" <<CASK
cask "byte-ports" do
  version "$version"
  sha256 "$checksum"

  url "https://github.com/Byte-de/ports/releases/download/v#{version}/Byte-Ports.dmg",
      verified: "github.com/Byte-de/ports/"
  name "Byte Ports"
  desc "Local dev servers, AI agents, projects and Cloudflare previews"
  homepage "https://ports.byte.de/"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :tahoe
  depends_on arch: :arm64

  app "Byte Ports.app"

  zap trash: [
    "~/Library/Application Support/Byte Ports",
    "~/Library/Caches/de.byte.ports",
    "~/Library/HTTPStorages/de.byte.ports",
    "~/Library/Preferences/de.byte.ports.plist",
    "~/Library/Saved Application State/de.byte.ports.savedState",
  ]
end
CASK
printf 'Verified cask written to %s\n' "$output"
