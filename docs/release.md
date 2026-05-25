# Release pipeline

The app ships auto-updates via [Sparkle 2.x](https://sparkle-project.org/). This document
walks the one-time setup and the per-release steps.

## One-time setup (do once, ever)

1. **Generate the Ed25519 keypair.** Sparkle ships a `generate_keys` binary in its SPM
   product's bundled tools. After the first `swift build`:

   ```sh
   # Locate the binary (path varies by Swift toolchain)
   find ~/Library/Developer/Xcode/DerivedData -name generate_keys -path '*Sparkle*' | head -1

   # Run it
   /path/to/generate_keys
   ```

   The tool stores the **private** key in your login keychain (label
   `https://sparkle-project.org`). Do not export it; do not commit it.

2. **Paste the public key into `Resources/Info.plist`.** Replace the placeholder string
   under `SUPublicEDKey`. This is the key Sparkle uses on every user's machine to verify
   downloaded updates.

3. **Stand up the appcast URL.** `https://anglesite.dev/appcast.xml` is the configured
   feed (see `SUFeedURL` in `Info.plist`). Two reasonable hosting paths:
   - Static file on a CDN/CF Pages, manually updated each release
   - GitHub Releases + a script that regenerates `appcast.xml` from the `gh release list`
     output

## Per-release steps

The build-plan calls for a `scripts/release.sh` that performs the full pipeline. Today
that script is a stub — `scripts/release.sh` exists but only prints the checklist below.
Wire it up to a CI workflow once the steady state is settled.

The manual checklist (until the script is finished):

1. Bump `MARKETING_VERSION` (and optionally `CURRENT_PROJECT_VERSION`) in `project.yml`,
   then `xcodegen generate`.
2. `xcodebuild archive -project Anglesite.xcodeproj -scheme Anglesite -configuration Release -archivePath build/Anglesite.xcarchive`
3. Export the .app with Developer ID signing: `xcodebuild -exportArchive`
4. Notarize: `xcrun notarytool submit Anglesite.zip --keychain-profile <profile> --wait`
5. Staple: `xcrun stapler staple Anglesite.app`
6. Sign the update package with Sparkle's `sign_update` (uses the private key from the
   keychain) — produces an `ed25519` signature string.
7. Update `appcast.xml` with the new `<item>` block (version, URL, signature, length).
8. Upload the .app (zipped or .dmg) + `appcast.xml` to the hosting destination.

Sparkle's documentation has reference scripts for steps 6–8:
<https://sparkle-project.org/documentation/publishing/>.
