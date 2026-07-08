# Release Pipeline

Anglesite ships through the Mac App Store only.

The single app target is `Anglesite` with bundle id `io.dwk.anglesite`. It is
sandboxed, uses App Store signing, and gets updates from App Store Connect. There
is no direct-download update feed, GitHub Release artifact, or notarized zip path.

## One-Time Setup

1. **App Store Connect app record.** Create an app for bundle id
   `io.dwk.anglesite` in [App Store Connect](https://appstoreconnect.apple.com/).
   The build will not upload until the record exists.

2. **Certificates.** In the Apple Developer portal, create and install in your
   login keychain:
   - an **Apple Distribution** certificate, which signs the `.app`;
   - a **Mac Installer Distribution** certificate, which signs the outer `.pkg`.

   Also install the **Apple WWDR** intermediate from
   <https://www.apple.com/certificateauthority/>. `scripts/release.sh`
   preflights these and fails early if any are missing.

3. **Provisioning profile.** Create a **Mac App Store** provisioning profile for
   `io.dwk.anglesite` tied to the Apple Distribution cert, download it, and
   install it. Note its name; pass it as `PROVISIONING_PROFILE`.

4. **Virtualization entitlement — nothing to request.** The app entitlement file
   includes `com.apple.security.virtualization` for Apple Containerization. It is an
   unrestricted entitlement: it is not a portal capability, needs no Apple approval,
   and is honored under any signature (even ad-hoc Debug builds boot containers —
   verified 2026-07-07). A standard Mac App Store profile suffices; confirm upload
   validation accepts it with `scripts/release.sh --validate-only` (precedent: the
   sandboxed `try-containers/Containers` app ships it on the Mac App Store).

5. **App Store Connect API key.** In App Store Connect -> Users and Access ->
   Integrations -> App Store Connect API, create a key with the App Manager role.
   Put the `.p8` in `~/.appstoreconnect/private_keys/` or `~/.private_keys/`, and
   record the Key ID and Issuer ID.

## Per-Release Flow

Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml` if needed,
then run:

```sh
TEAM_ID=YOUR_TEAM_ID \
PROVISIONING_PROFILE="Anglesite App Store" \
ASC_API_KEY_ID=XXXXXXXXXX \
ASC_API_ISSUER_ID=00000000-0000-0000-0000-000000000000 \
  scripts/release.sh
```

The script:

1. runs `xcodegen generate`;
2. archives the `Anglesite` scheme;
3. verifies the archived app signature and Team ID;
4. exports, and unless `--validate-only` uploads, an App Store `.pkg` via
   `xcodebuild -exportArchive`.

Use `--validate-only` to archive/export/validate without uploading. Transporter
is still a valid manual fallback: drop the exported `.pkg` onto Transporter.app.
