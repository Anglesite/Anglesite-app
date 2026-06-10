# Xcode project setup (Phase 0.5)

The SwiftPM scaffold (Phase 0.3) builds and tests via `swift build` / `swift test`. To produce a notarizable `.app` bundle and run on macOS as a real GUI app, we also need an Xcode project with a macOS App target. The `.xcodeproj` is **generated from [`project.yml`](../project.yml) via [XcodeGen](https://github.com/yonaskolb/XcodeGen)** — it is not hand-managed and is gitignored.

## Why both SwiftPM and Xcode?

- **SwiftPM** drives CI (`swift test`), keeps the module graph clean, and lets contributors build core/bridge code without Xcode.
- **Xcode project** owns the macOS App target — Info.plist, entitlements, signing, build phases for vendoring Node and the plugin, notarization.

`Anglesite.xcodeproj` references the SwiftPM package as a local dependency (the `Anglesite` package declared in this repo's root `Package.swift`), so source files live in `Sources/` and are shared between both build paths.

## Targets and bundle ids

Two app targets are generated from `project.yml`:

| Target | Bundle id | Distribution | Sandbox |
|---|---|---|---|
| `Anglesite` | `dev.anglesite.app` | Developer ID (notarized) + Sparkle | off (Hardened Runtime on) |
| `AnglesiteMAS` | `dev.anglesite.app.mas` | Mac App Store | App Sandbox (Hardened Runtime on) |

`dev.anglesite.app` matches the planned `anglesite.dev` distribution domain (design doc §10). The MAS target shares all `Sources/AnglesiteApp` code; its differences are gated by the `ANGLESITE_MAS` compile flag and a postBuildScript that re-signs the bundled Node for the sandbox (`scripts/resign-node.sh`). The MAS target emits `AnglesiteMAS.app` (`PRODUCT_NAME: AnglesiteMAS`) so it doesn't collide with the DevID `Anglesite.app` in the shared Products dir; its user-visible name stays "Anglesite" via `CFBundleDisplayName`.

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

| Target | Config | Identity | Apple account needed | Use for |
|---|---|---|---|---|
| `Anglesite` | `Debug` | ad-hoc (`-`) | none | Local development, running on your own Mac |
| `Anglesite` | `Release` | `Developer ID Application` | **paid** Apple Developer Program ($99/yr) | Notarized distribution via `anglesite.dev` |
| `AnglesiteMAS` | `Debug` | ad-hoc (`-`) | none | Local development of the sandboxed build |
| `AnglesiteMAS` | `Release` | `Apple Distribution` | **paid** Apple Developer Program | Mac App Store submission |

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

- **DMG packaging** — `scripts/package-dmg.sh` is not yet built; `scripts/release.sh` ships a notarized zip.
- **App Store Connect submission** — the sandboxed `AnglesiteMAS` target exists and builds (Phase 10.1); the archive/export/upload pipeline is Task 12.
- **Notarization for DevID** — `scripts/notarize-dry-run.sh` is ready; blocked on the signing cert + `TEAM_ID`.

## What's shipped (since Phase 0.5)

- **Sparkle auto-update** — landed in Phase 8 (DevID target only; the MAS build updates via the App Store). Manual key/appcast setup remains (see [`docs/release.md`](release.md)).
- **Phases 0–9 complete** — embedded Node, plugin plumbing, subprocess supervisor, WKWebView edit overlay, deploy, Keychain, chat panel, multi-window, health badge, image drop, per-edit undo.
- **Phase 10** in progress — sandboxed MAS build (Tasks 11–13 remaining), Apple Help Book shipped, Xcode 27 migration done.
