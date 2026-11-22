# ADR-0003: Distribution channels

Date: 2026-11-22 · Status: accepted (zero-cost: no paid store or developer accounts)

## Context
Owner ships via GitHub Releases with no paid Apple account, and has done this before for macOS
(SnapClip): a `curl | bash` installer downloads the zip, copies the app to /Applications and
removes quarantine. Files fetched by curl normally carry no quarantine flag, so Gatekeeper's
notarization check does not block launch. iPhone apps cannot be installed this way.

## Decision
- macOS: universal (arm64 + x86_64) build, ad-hoc signed ("Sign to Run Locally"), zipped with
  `ditto`, published with SHA256SUMS; installed by `scripts/install-macos.sh` (checksum + codesign
  verification, removes only `com.apple.quarantine`). Manual zip download documented as fallback
  (right-click → Open, or System Settings → Privacy & Security → Open Anyway).
- Android: APK signed with our own release key on GitHub Releases.
- Windows: installer on GitHub Releases; unsigned (SmartScreen "More info → Run anyway") until a
  signing option is affordable.
- iOS: no App Store/TestFlight. Users build from source in Xcode with a free Apple ID
  (provisioning expires after 7 days; rebuild to renew), or sideload a released unsigned .ipa with
  a free re-signing tool such as AltStore/SideStore (same 7-day limit). Documented, not automated.
- Android: since 30 Sep 2026 certified devices in Brazil, Indonesia, Singapore and Thailand only
  install apps from registered developers (global from 2027). Zero-cost path: Google's free
  limited-distribution account (up to 20 devices) or users install via the advanced unverified
  flow / ADB. Re-check before each release.

## Consequences (ad-hoc signing)
- Keychain: no team ID, so no keychain access groups; ACL is bound to the build's code hash, so
  after an update macOS may prompt once for keychain access, or the user signs in to Google again.
  Test in release checklist; fallback is re-auth, never storing tokens outside Keychain.
- Updates: in-app check against GitHub Releases (EdDSA-signed appcast via Sparkle, no Apple cert needed).
- Users must trust the repo: checksum proves integrity of the download, not authorship. Signed
  release tags + the checksum file in the same release are the trust anchor.
