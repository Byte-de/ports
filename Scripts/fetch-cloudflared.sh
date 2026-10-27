#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/toolchain.sh"
version=2026.10.5
case "$(uname -m)" in
  arm64) architecture=arm64; checksum=184c7d4f5f977348243a6d7ca8f6cf6073b9b2746cfe8c1fe15aa59e9a522bf0 ;;
  x86_64) architecture=amd64; checksum=6699392fed92367808c248c2d90bed66e49bbf66e1b4ee3e4141230f3f7391b3 ;;
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
