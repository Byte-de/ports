# Releasing Byte Ports

## Version and support policy

Public versions start at **1.0.0**. `Resources/Info.plist` is the app's version
source. Increment its short version for the release and its integer build number
for every distributed build. Match the changelog, Git tag, website version and
Homebrew cask. Do not expose prototype build versions as public releases.

The distribution target is macOS 26+, arm64. A change to supported platforms must
be validated on real hardware before expanding that claim.

## One-time credentials

Local releases need a **Developer ID Application** identity in the user's keychain
and a `notarytool` profile named `BYTE_NOTARY`. Apple Developer agreements must be
accepted by the account holder. Never copy private keys into the repository.

GitHub's `release` environment requires these secrets:

- `DEVID_CERT_P12_BASE64`, `DEVID_CERT_PASSWORD`
- `ASC_API_KEY_P8_BASE64`, `ASC_KEY_ID`, `ASC_ISSUER_ID`

The workflow uses a temporary keychain and deletes it even after failure. Keep
release-environment access limited to maintainers. No production download is
published when signing, notarization, stapling or Gatekeeper assessment fails.

## Local release

```sh
SIGN_IDENTITY='Developer ID Application: YOUR ORGANISATION (TEAMID)' \
NOTARY_PROFILE=BYTE_NOTARY Scripts/release.sh /tmp/ports-release
```

The script checks credentials, tests, builds, signs all executables with Hardened
Runtime and timestamps, notarizes/staples the app, creates a drag-to-Applications
DMG, then signs/notarizes/staples and assesses the DMG. Only successful results are
copied to the destination. `SHA256SUMS` authenticates file integrity when compared
to the trusted release page; it is not a substitute for Developer ID verification.

Before publishing, mount the DMG read-only, copy the app to an empty test location,
run `codesign --verify --deep --strict`, `spctl --assess --type execute`, and
`xcrun stapler validate`, then launch with an isolated state directory. Test an
ordinary quarantined browser download on another Mac for the final user path.
Do not remove quarantine attributes or disable Gatekeeper.

## Publish

1. Complete the verification matrix and commit the final source with a clean tree.
2. Tag that exact commit `vX.Y.Z` and push the tag.
3. Run the Release workflow for the tag, or upload locally verified assets with
   `gh release create --verify-tag --notes-file`.
4. Keep the download asset named **Byte-Ports.dmg** for the stable latest-download URL.
5. Generate the cask with `Scripts/prepare-homebrew.sh /tmp/ports-release/Byte-Ports.dmg /tmp/byte-ports.rb`, then add it to `Byte-de/homebrew-tap` as `Casks/byte-ports.rb`. The helper rejects an unnotarized DMG.
6. Update and deploy the separate Ports website; set `released: true` only after
   the download and tap resolve. The website must not advertise unavailable assets.
7. Verify HTTPS, download checksum, site links and the app's manual update check.

The first public Git history starts from the cleaned source snapshot. Do not add
internal archives, screenshots, legacy design documents or generated binaries.
Source archives should come from `git archive` so ignored files cannot leak in.

## Bundled cloudflared

`Scripts/fetch-cloudflared.sh` pins its version and both upstream archive hashes.
The scheduled check reports newer vendor releases; it never silently replaces a
binary. Review the vendor release notes, obtain checksums from the official release,
refresh `Resources/ThirdParty`, run all tests and a disposable end-to-end preview,
then include the update in the next app release. No runtime binary auto-update.
Pin each darwin `.tgz` asset's GitHub digest. The release notes list the SHA-256 of
the extracted `cloudflared` executable instead, so compare that after extraction.

## Rollback

Never overwrite a versioned public release with different bytes. If a critical
fault is found, mark it clearly in the release notes, remove the latest designation
if appropriate, and ship an incremented fixed version. Keep older releases for
reproducibility. The in-app check offers only newer stable tags and never downgrades.
