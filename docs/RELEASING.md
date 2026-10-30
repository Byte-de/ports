# Releasing Byte Ports

## Version and support policy

Public versions start at **1.0.0**. `Resources/Info.plist` is the app's version
source. Increment its short version for the release and its integer build number
for every distributed build. Match the changelog, Git tag, website version and
Homebrew cask. Do not expose prototype build versions as public releases. The
first public release stays 1.0.0 until it is published; each release candidate
gets the next build number instead (build 3 is the current one).

The distribution target is macOS 26+, arm64. A change to supported platforms must
be validated on real hardware before expanding that claim.

## One-time credentials

Local releases need a **Developer ID Application** identity in the user's keychain
and a `notarytool` profile named `BYTE_NOTARY`. Apple Developer agreements must be
accepted by the account holder. Never copy private keys into the repository.

The Release workflow needs these repository secrets (Settings › Secrets and
variables › Actions; its `release` environment reads them too):

- `DEVID_CERT_P12_BASE64`: the "Developer ID Application" certificate with its
  private key, exported from Keychain Access as .p12, then `base64 -i cert.p12`.
- `DEVID_CERT_PASSWORD`: the password chosen for that .p12 export.
- `ASC_API_KEY_P8_BASE64`: an App Store Connect API key (`base64 -i AuthKey_ID.p8`).
- `ASC_KEY_ID`, `ASC_ISSUER_ID`: the key's ID and the team's issuer ID (App Store
  Connect › Users and Access › Integrations › App Store Connect API).

The workflow uses a temporary keychain and deletes it even after failure. Keep
release-environment access limited to maintainers. No production download is
published when signing, notarization, stapling or Gatekeeper assessment fails.

Locally, store the same API key once as the `BYTE_NOTARY` profile. With only the
Command Line Tools installed (no accepted Xcode license), prefix `xcrun` with
`DEVELOPER_DIR=/Library/Developer/CommandLineTools`:

```sh
xcrun notarytool store-credentials BYTE_NOTARY --key AuthKey_ID.p8 --key-id ID --issuer ISSUER-UUID
```

### Signing and notarization over time

- **Every build is notarized again.** Notarization belongs to the exact bytes
  Apple scanned, so each new version needs its own submission. The Release
  workflow does this on every version tag; nobody has to notarize by hand.
- **The Developer ID certificate expires on 1 February 2027.** Builds signed
  before then keep working, because the signatures carry a secure timestamp. To
  release afterwards, create a new "Developer ID Application" certificate in the
  Apple Developer account (Nord Ventures GmbH, team U2G2QZYSPC), export it with
  its key as .p12, and replace `DEVID_CERT_P12_BASE64` and `DEVID_CERT_PASSWORD`.
  Renew a few weeks early: the workflow fails closed at the signing step otherwise.
- **The App Store Connect API key does not expire**, but a revoked key stops
  notarization. Then create a new key and replace `ASC_API_KEY_P8_BASE64` and
  `ASC_KEY_ID` (and the local `BYTE_NOTARY` profile). Apple lets you download a
  .p8 only once; keep it in the team's password manager.
- **Agreements.** When Apple publishes new developer agreements, notarization
  answers HTTP 403 until the account holder accepts them in the developer account.

## Local release

```sh
SIGN_IDENTITY='Developer ID Application: YOUR ORGANISATION (TEAMID)' \
NOTARY_PROFILE=BYTE_NOTARY Scripts/release.sh /tmp/ports-release
```

The script checks credentials, runs `Scripts/lint.sh` and `Scripts/check.sh`,
builds, signs all executables with Hardened Runtime and timestamps, validates the
bundle contract (`Scripts/validate-bundle.sh`), smoke-launches the app (this needs
a GUI login session), notarizes/staples the app and validates it again, creates a
drag-to-Applications DMG, then signs/notarizes/staples and assesses the DMG. Only
successful results are copied to the destination. `SHA256SUMS` authenticates file
integrity when compared to the trusted release page; it is not a substitute for
Developer ID verification.

Before publishing, mount the DMG read-only, copy the app to an empty test location,
run `codesign --verify --deep --strict`, `spctl --assess --type execute`, and
`xcrun stapler validate`, then launch with an isolated state directory. Test an
ordinary quarantined browser download on another Mac for the final user path.
Do not remove quarantine attributes or disable Gatekeeper.

## Publish

Releases are automatic: pushing a version tag `vX.Y.Z` makes the Release workflow
build, sign, notarize and staple Byte Ports, and publish Byte-Ports.dmg as the
**latest** GitHub release. The website's download button and the README point to
`https://github.com/Byte-de/ports/releases/latest/download/Byte-Ports.dmg`, so they
serve the new version as soon as the workflow finishes, and the app's update check
finds it. Ordinary pushes to `main` only run the Check workflow; they never publish.

1. Raise `CFBundleShortVersionString` in `Resources/Info.plist` for the new version
   and `CFBundleVersion` (the integer build number) for every distributed build.
2. Add a `## X.Y.Z` section at the top of `CHANGELOG.md`. Its text becomes the
   release notes; a heading that still says `(unreleased)` stops the workflow.
   When a release changes what the app sends over the network, update the
   website's privacy notice first.
3. Complete the relevant checks in [VERIFICATION.md](VERIFICATION.md), including a
   green "Check bundled cloudflared" workflow, and push the commit to `main`.
4. Run `Scripts/tag-release.sh --push`. It checks the version, the build number,
   the CHANGELOG section and that `main` is pushed, then pushes the tag.
5. Watch the Release workflow (`gh run watch`). It refuses to replace a version that
   is already published. To retry a failed run for an existing tag, use "Run
   workflow" with that tag. Keep the asset name **Byte-Ports.dmg**.
6. Update the Homebrew cask: download the published DMG
   (`gh release download vX.Y.Z -R Byte-de/ports -p Byte-Ports.dmg -D /tmp/ports-release`),
   run `Scripts/prepare-homebrew.sh /tmp/ports-release/Byte-Ports.dmg /tmp/byte-ports.rb`
   and commit the result to `Byte-de/homebrew-tap` as `Casks/byte-ports.rb`. The
   helper rejects an unnotarized DMG.
7. For the first release only: deploy the website with `released: true` once the
   download and the tap resolve. Later releases need no website change, except
   its changelog page (`src/content/changelog.ts` mirrors `CHANGELOG.md`).
8. Verify HTTPS, download checksum, site links and the app's manual update check.

A locally verified build (`Scripts/release.sh`) can also be uploaded by hand with
`gh release create vX.Y.Z --verify-tag --latest --notes-file <section> Byte-Ports.dmg SHA256SUMS`.

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
