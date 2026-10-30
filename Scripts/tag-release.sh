#!/bin/bash
# Tags the version in Resources/Info.plist so the Release workflow builds, notarizes and publishes it as the latest
# release. Run it on an up-to-date main with a clean tree. Without --push it only creates the tag locally.
set -euo pipefail
cd "$(dirname "$0")/.."
die() { echo "$1" >&2; exit 1; }
push=false
[[ "${1:-}" == "--push" ]] && push=true
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
build=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' Resources/Info.plist)
tag="v$version"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "CFBundleShortVersionString must be X.Y.Z, not $version."
[[ "$build" =~ ^[1-9][0-9]*$ ]] || die "CFBundleVersion must be a positive integer, not $build."
[[ -z "$(git status --porcelain)" ]] || die "Commit or stash your changes first."
[[ "$(git rev-parse --abbrev-ref HEAD)" == main ]] || die "Release from main."
git fetch --quiet --tags origin main
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || die "Push main first: the tag must point at a pushed commit."
if git rev-parse --quiet --verify "refs/tags/$tag" >/dev/null; then
  die "$tag exists. Raise CFBundleShortVersionString (and the build number) for a new release."
fi
if grep -q "^## $version (unreleased)" CHANGELOG.md; then die "Remove (unreleased) from the $version CHANGELOG heading."; fi
notes=$(awk -v version="$version" '/^## / { if (found) exit; found = ($2 == version); next } found' CHANGELOG.md)
[[ "$notes" =~ [^[:space:]] ]] || die "CHANGELOG.md has no '## $version' section."
# Every distributed build gets a higher build number than the release before it.
if previous=$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null); then
  previous_build=$(git show "$previous:Resources/Info.plist" | plutil -extract CFBundleVersion raw -)
  (( build > previous_build )) || die "Build $build must be higher than $previous_build of $previous."
fi
git tag -a "$tag" -m "Byte Ports $version"
if $push; then
  git push origin "$tag"
  echo "Pushed $tag: the Release workflow now builds, notarizes and publishes it."
else
  echo "Tagged $tag locally. Push it with: git push origin $tag"
fi
