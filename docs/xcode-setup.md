# Xcode project setup (Phase 0.5)

The SwiftPM scaffold (Phase 0.3) builds and tests via `swift build` / `swift test`. To produce a notarizable `.app` bundle and run on macOS as a real GUI app, we also need an Xcode project with a macOS App target. The `.xcodeproj` is **generated from [`project.yml`](../project.yml) via [XcodeGen](https://github.com/yonaskolb/XcodeGen)** — it is not hand-managed and is gitignored.

## Why both SwiftPM and Xcode?

- **SwiftPM** drives CI (`swift test`), keeps the module graph clean, and lets contributors build core/bridge code without Xcode.
- **Xcode project** owns the macOS App target — Info.plist, entitlements, signing, build phases for vendoring Node and the plugin, notarization.

`Anglesite.xcodeproj` references the SwiftPM package as a local dependency (the `Anglesite` package declared in this repo's root `Package.swift`), so source files live in `Sources/` and are shared between both build paths.

## Bundle id

**`dev.anglesite.app`** — matches the planned `anglesite.dev` distribution domain (design doc §10).

## One-time setup

1. Install XcodeGen if you don't have it:
   ```sh
   brew install xcodegen
   ```
2. Generate the Xcode project:
   ```sh
   xcodegen generate
   ```
   This reads `project.yml` and writes `Anglesite.xcodeproj/`. Re-run any time you change `project.yml`, or before a fresh build to be safe — `scripts/notarize-dry-run.sh` already does this for you.
3. Open the project (optional, only if you want the Xcode UI):
   ```sh
   xed Anglesite.xcodeproj
   ```

Everything from this point on — Info.plist, entitlements, deployment target, hardened runtime, signing identity — is configured by `project.yml`. **Edit `project.yml`, not the `.xcodeproj`.** Any manual `.xcodeproj` change will be lost the next time XcodeGen runs.

## Signing configurations

| Config | Identity | Apple account needed | Use for |
|---|---|---|---|
| `Debug` | ad-hoc (`-`) | none | Local development, running on your own Mac |
| `Release` | `Developer ID Application` | **paid** Apple Developer Program ($99/yr) | Notarized distribution via `anglesite.dev` |

Debug builds run on the local machine without any Apple account at all — the binary gets an anonymous ad-hoc signature, which is enough to run but not to distribute. All Phase 1+ development (embedded Node, MCP, WKWebView edit overlay) can be built and exercised in this config indefinitely.

## Verify Debug signing (no Apple account needed)

```sh
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug \
  -derivedDataPath build/DerivedData build
APP=build/DerivedData/Build/Products/Debug/Anglesite.app
codesign --display --verbose=2 "$APP" 2>&1 | grep -E "(Signature|TeamIdentifier|flags)"
# Expect: Signature=adhoc
# Expect: TeamIdentifier=not set
# Expect: flags=0x2(adhoc)
```

`spctl --assess` will *reject* an ad-hoc-signed app — that's correct, Gatekeeper only approves notarized builds. The app still launches when opened locally.

## Notarization dry run (requires paid Apple Developer account)

Before any real code lands, prove the notarization path works end-to-end with the empty Phase-0 app. The five acceptance steps for [issue #1](https://github.com/Anglesite/Anglesite-app/issues/1) are wrapped in [`scripts/notarize-dry-run.sh`](../scripts/notarize-dry-run.sh).

First-time setup — store an app-specific password for notarytool:

```sh
xcrun notarytool store-credentials AC_PASSWORD \
  --apple-id you@example.com \
  --team-id YOUR_TEAM_ID \
  --password <app-specific-password-from-appleid.apple.com>
```

Then run the dry run:

```sh
TEAM_ID=YOUR_TEAM_ID scripts/notarize-dry-run.sh
```

The script runs the six steps in order (XcodeGen regen plus the five acceptance checks):

0. `xcodegen generate` → fresh `Anglesite.xcodeproj/`
1. `xcodebuild archive` → `build/Anglesite.xcarchive`
2. `xcodebuild -exportArchive` → `build/export/Anglesite.app` (uses [`scripts/exportOptions.plist`](../scripts/exportOptions.plist) as a template; `$TEAM_ID` is substituted into `build/exportOptions.plist`)
3. `xcrun notarytool submit --wait` → status `Accepted`
4. `xcrun stapler staple` → ticket attached
5. `spctl --assess` → grep'd for `source=Notarized Developer ID`

Override defaults via env vars: `SCHEME`, `CONFIGURATION`, `KEYCHAIN_PROFILE`.

## What's deferred

- **Auto-update (Sparkle)** — Phase 8 (v0.5 milestone).
- **DMG packaging** — once Phase 1 (embedded Node) lands, we'll add a `scripts/package-dmg.sh`.
- **App Store Connect / sandboxed build** — Phase 10 (v2).

## After Phase 0.5

When the notarization dry run passes, mark Phase 0 complete and move to **Phase 1: Embedded Node runtime**.
