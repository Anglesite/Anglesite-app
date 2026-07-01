# Release pipeline

Anglesite ships on two tracks:

- **Developer ID** (the `Anglesite` target) — self-distributed, auto-updated via
  [Sparkle 2.x](https://sparkle-project.org/). Driven by `scripts/release.sh`.
- **Mac App Store** (the sandboxed `AnglesiteMAS` target) — distributed through App Store
  Connect, which handles its own updates (no Sparkle). Driven by `scripts/release-mas.sh`.
  See [Mac App Store submission](#mac-app-store-submission) below.

The first part of this document walks the Developer ID one-time setup and per-release flow;
the App Store section follows.

## One-time setup (do once, ever)

1. **Generate the Ed25519 keypair.** Sparkle ships `generate_keys` in its SPM product's
   bundled tools. After building the Anglesite scheme at least once:

   ```sh
   find ~/Library/Developer/Xcode/DerivedData -name generate_keys -path '*Sparkle*/bin/generate_keys' | head -1
   # then run that path; or to print an already-generated public key without creating new keys:
   /path/to/generate_keys -p
   ```

   The tool stores the **private** key in your login keychain under label
   `https://sparkle-project.org`. Do not export it; do not commit it.

2. **Paste the public key into `Resources/Info.plist`.** Replace the `SUPublicEDKey`
   placeholder with the base64 string printed by `generate_keys`. This is the key Sparkle
   uses on every user's machine to verify downloaded updates.

3. **Set up appcast hosting.** `SUFeedURL` in `Info.plist` points at
   `https://anglesite.dev/appcast.xml`. The plan is to serve it from a `gh-pages` branch
   of this repo with `anglesite.dev` configured as a GitHub Pages custom domain. Until that
   DNS work is done, the in-app "Check for Updates…" will fail with a network error.

   Steps when ready:
   - Create the `gh-pages` branch (orphan) and push a `CNAME` file containing `anglesite.dev`.
   - In repo Settings → Pages: set source to `gh-pages` / root.
   - At your DNS provider, point `anglesite.dev` (and `www.anglesite.dev`) at GitHub Pages'
     A records (185.199.108.153, .109.153, .110.153, .111.153) and an AAAA record set.
   - Wait for Pages to issue the cert (a few minutes).

4. **Set up `notarytool` credentials** (one-time, per machine):

   ```sh
   xcrun notarytool store-credentials AC_PASSWORD \
     --apple-id you@example.com \
     --team-id YOUR_TEAM_ID \
     --password <app-specific-password>
   ```

## Per-release flow

Once the one-time setup is done:

```sh
TEAM_ID=YOUR_TEAM_ID scripts/release.sh 0.2.0
```

The script:

1. Bumps `MARKETING_VERSION` (from the arg) and increments `CURRENT_PROJECT_VERSION` in
   `project.yml`.
2. Runs `scripts/notarize-dry-run.sh` (archive → exportArchive → notarytool → stapler → spctl).
3. Zips the resulting `.app` with `ditto`.
4. Signs the zip with Sparkle's `sign_update` (reads private key from your Keychain) and
   captures `edSignature` + `length`.
5. Commits the version bump and tags `vX.Y.Z`.
6. Pushes to `origin/main`.
7. Creates the GitHub Release, uploads the zip, and embeds `<!-- sparkle-* -->` markers in
   the release body so the appcast generator can read them later.
8. Regenerates `build/appcast.xml` by walking every published GitHub Release and parsing
   its sparkle-* markers.

### After the script finishes

The appcast.xml isn't pushed automatically — copy it to the `gh-pages` branch:

```sh
git worktree add ../Anglesite-app-pages gh-pages
cp build/appcast.xml ../Anglesite-app-pages/appcast.xml
(cd ../Anglesite-app-pages && git add appcast.xml \
  && git commit -m "appcast: 0.2.0" && git push)
```

Then test the in-app "Check for Updates…" against the new release.

## Regenerating just the appcast

If you need to rebuild the feed (e.g. after manually editing a release's body):

```sh
scripts/generate-appcast.sh build/appcast.xml
```

Drafts and prereleases are skipped. Releases missing the sparkle-* markers are skipped
with a warning.

## Mac App Store submission

The sandboxed `AnglesiteMAS` target submits to App Store Connect via
`scripts/release-mas.sh`. This is the App Store counterpart to the Developer ID flow above —
no Sparkle, no appcast, no GitHub Release; App Store Connect is the distribution channel and
ships updates itself.

### One-time setup (App Store)

1. **App Store Connect app record.** Create an app for bundle id `io.dwk.anglesite`
   in [App Store Connect](https://appstoreconnect.apple.com/) → Apps. The build won't
   upload until the record exists.

2. **Certificates.** In the Apple Developer portal, create and install in your login keychain:
   - an **Apple Distribution** certificate (signs the `.app`), and
   - a **Mac Installer Distribution** certificate (signs the outer `.pkg`).
   Also install the **Apple WWDR (G3)** intermediate from
   <https://www.apple.com/certificateauthority/> — without it the distribution chain won't
   validate at upload. `release-mas.sh` preflights all three and fails early with a pointer
   if any is missing.

3. **Provisioning profile.** Create a **Mac App Store** provisioning profile for
   `io.dwk.anglesite` tied to the Apple Distribution cert, download it, and install it
   (double-click, or drop into `~/Library/MobileDevice/Provisioning Profiles/`). Note its
   name — you pass it as `PROVISIONING_PROFILE`.

4. **App Store Connect API key** (keychain-free uploads). In App Store Connect → Users and
   Access → Integrations → App Store Connect API, create a key with the *App Manager* role.
   Download the `.p8` once and place it in `~/.appstoreconnect/private_keys/` (or
   `~/.private_keys/`). Record the **Key ID** and **Issuer ID** — they become
   `ASC_API_KEY_ID` and `ASC_API_ISSUER_ID`.

### Per-release flow (App Store)

Bump the version first if needed (same `project.yml` keys the Developer ID flow bumps —
`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`; App Store builds must use a build number
not previously uploaded for that version). Then:

```sh
TEAM_ID=YOUR_TEAM_ID \
PROVISIONING_PROFILE="Anglesite MAS App Store" \
ASC_API_KEY_ID=XXXXXXXXXX \
ASC_API_ISSUER_ID=00000000-0000-0000-0000-000000000000 \
  scripts/release-mas.sh
```

The script:

1. **Preflights** `TEAM_ID`, the provisioning profile, `xcodegen`/`xcodebuild`/`altool`, the
   Apple Distribution + Mac Installer Distribution identities, the WWDR intermediate, and (for
   upload) the ASC API key/issuer.
2. Runs `xcodegen generate` and writes `build/exportOptions-appstore.plist` from the template
   (`scripts/exportOptions-appstore.plist`, `method = app-store-connect`), substituting
   `TEAM_ID` and the profile name.
3. `xcodebuild archive` of the `AnglesiteMAS` scheme (Release).
4. **Verifies the bundled-Node re-sign survived the archive** — `codesign --verify` on the
   embedded `node`, and that its `TeamIdentifier` matches the app's team. This is the
   `scripts/resign-node.sh` post-build phase's output; if it didn't hold, the bundle seal and
   App Store acceptance would fail.
5. `xcodebuild -exportArchive` → a Mac Installer Distribution-signed `.pkg`.
6. `xcrun altool --validate-app`, then `xcrun altool --upload-app`.

Pass **`--validate-only`** to archive, export, and validate without uploading — the
credential-free dry run analogous to `notarize-dry-run.sh`. (`ASC_API_KEY_ID` /
`ASC_API_ISSUER_ID` are still needed for the App Store Connect *validation* step; without them
the script skips ASC validation and just produces the `.pkg`.)

`Transporter.app` is the GUI fallback for the upload step: drop the exported `.pkg` onto it.

### After upload

App Store Connect processes the build (a few minutes), after which it appears under
TestFlight / the app version. Attach it to a version and submit for review there.

## Why a `release.sh` and not CI?

Today releases are driven from a developer machine because the signing keys (Apple
Developer ID, Sparkle Ed25519) live in the macOS Keychain. Moving to CI requires either
GitHub Actions secrets for the signing identity + Sparkle private key (and a hardened
self-hosted macOS runner), or a third-party signing service. That's deferred; the script
documents the steady-state so the move is mechanical when we're ready.
