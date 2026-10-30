#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/toolchain.sh"
version=2026.10.6
case "$(uname -m)" in
  arm64) architecture=arm64; checksum=ea1e5105d35bbe16cee5b2f7b4742059ada341fbd35938ed827c24b85efa51c8 ;;
  x86_64) architecture=amd64; checksum=6c04a13835ca5ff29a0c6f58d17d1f3956aad1b7df1631f5b5efbc06269deded ;;
  *) printf 'Unsupported Cloudflare architecture\n' >&2; exit 1 ;;
esac
cache="$build_directory/cloudflared-$version-$architecture"
mkdir -p "$cache"
archive="$cache/cloudflared.tgz"
if [[ ! -f "$archive" ]]; then
  /usr/bin/curl --fail --location --silent --show-error --connect-timeout 15 --max-time 180 \
    "https://github.com/cloudflare/cloudflared/releases/download/$version/cloudflared-darwin-$architecture.tgz" \
    -o "$archive.download"
  mv "$archive.download" "$archive"
fi
actual=$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print $1}')
[[ "$actual" == "$checksum" ]] || { printf 'Cloudflare checksum mismatch; download rejected\n' >&2; exit 1; }
# Extract only the expected regular binary from the verified release asset.
/usr/bin/tar -xzf "$archive" -C "$cache" cloudflared
[[ -f "$cache/cloudflared" && ! -L "$cache/cloudflared" ]] || exit 1
chmod 755 "$cache/cloudflared"
printf '%s\n' "$cache/cloudflared"
