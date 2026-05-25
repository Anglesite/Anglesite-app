# Release pipeline

The app ships auto-updates via [Sparkle 2.x](https://sparkle-project.org/). This document
walks the one-time setup and the per-release flow.

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

## Why a `release.sh` and not CI?

Today releases are driven from a developer machine because the signing keys (Apple
Developer ID, Sparkle Ed25519) live in the macOS Keychain. Moving to CI requires either
GitHub Actions secrets for the signing identity + Sparkle private key (and a hardened
self-hosted macOS runner), or a third-party signing service. That's deferred; the script
documents the steady-state so the move is mechanical when we're ready.
