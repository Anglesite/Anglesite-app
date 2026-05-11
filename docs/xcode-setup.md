# Xcode project setup (Phase 0.5)

The SwiftPM scaffold (Phase 0.3) builds and tests via `swift build` / `swift test`. To produce a notarizable `.app` bundle and run on macOS as a real GUI app, we also need an Xcode project with a macOS App target. This document walks through that one-time setup.

## Why both SwiftPM and Xcode?

- **SwiftPM** drives CI (`swift test`), keeps the module graph clean, and lets contributors build core/bridge code without Xcode.
- **Xcode project** owns the macOS App target — Info.plist, entitlements, signing, build phases for vendoring Node and the plugin, notarization.

The Xcode project will reference the SwiftPM package as a local dependency, so source files live in `Sources/` and stay shared between both build paths.

## Bundle id

**`dev.anglesite.app`** — matches the planned `anglesite.dev` distribution domain (design doc §10).

## One-time setup

1. **Open Xcode 16+.**
2. *File → New → Project…* → **macOS** → **App**.
   - Product name: `Anglesite`
   - Team: your Developer ID team
   - Organization identifier: `dev.anglesite`
   - Interface: **SwiftUI**
   - Language: **Swift**
   - Storage: **None**
   - Tests: **Off** (the SwiftPM test target already exists)
3. Save into `Anglesite-app/` (this directory). When prompted, **do not** create a new git repo — the repo already exists at the package root.
4. In the new project, **delete** the auto-generated `AnglesiteApp.swift` and `ContentView.swift` from the App target — we already have them in `Sources/AnglesiteApp/`.
5. *File → Add Package Dependencies… → Add Local…* → select this directory (`Anglesite-app/`). Add the `AnglesiteApp` product to the App target.
   - Actually, since the App target IS the executable, the cleaner path is: delete the App target's `Sources` folder and instead point the Xcode App target to compile `Sources/AnglesiteApp/*.swift` directly, with `AnglesiteCore` and `AnglesiteBridge` as package products. Document the path you took.
6. Replace the auto-generated `Info.plist` with `Resources/Info.plist`. *Build Settings → Info.plist File* → `Resources/Info.plist`.
7. Replace the auto-generated `.entitlements` with `Resources/Anglesite.entitlements`. *Build Settings → Code Signing Entitlements* → `Resources/Anglesite.entitlements`.
8. *Signing & Capabilities*:
   - **Team**: your Developer ID team
   - **Signing Certificate**: Developer ID Application (for direct distribution)
   - **Hardened Runtime**: ✅ on
   - **App Sandbox**: ❌ off (v0; revisit in v2)
9. *Build Settings → Deployment*:
   - macOS Deployment Target: **14.0**
10. Build (⌘B) — verify it produces `Anglesite.app` in DerivedData and launches.

## Verify signing

```sh
# After a successful build, locate the .app bundle:
APP=$(find ~/Library/Developer/Xcode/DerivedData -name "Anglesite.app" -path "*/Debug/*" -print -quit)

# Confirm it's signed with Hardened Runtime:
codesign --display --verbose=4 "$APP" 2>&1 | grep -E '(Authority|flags)'
# Expect: Authority=Developer ID Application: <your team>
# Expect: flags=0x10000(runtime)
```

## Notarization dry run

Before any real code lands, prove the notarization path works end-to-end with the empty Phase-0 app:

```sh
# 1. Archive
xcodebuild -scheme Anglesite -configuration Release \
  -archivePath build/Anglesite.xcarchive archive

# 2. Export with Developer ID
xcodebuild -exportArchive \
  -archivePath build/Anglesite.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist build/exportOptions.plist

# 3. Submit to Apple's notary service
xcrun notarytool submit build/export/Anglesite.app \
  --keychain-profile "AC_PASSWORD" \
  --wait

# 4. Staple the notarization ticket
xcrun stapler staple build/export/Anglesite.app

# 5. Verify
spctl --assess --type execute --verbose=4 build/export/Anglesite.app
# Expect: source=Notarized Developer ID
```

`build/exportOptions.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>YOUR_TEAM_ID</string>
    <key>signingStyle</key>
    <string>manual</string>
</dict>
</plist>
```

## What's deferred

- **Auto-update (Sparkle)** — Phase 8 (v0.5 milestone).
- **DMG packaging** — once Phase 1 (embedded Node) lands, we'll add a `scripts/package-dmg.sh`.
- **App Store Connect / sandboxed build** — Phase 10 (v2).

## After Phase 0.5

When the Xcode project exists and the notarization dry run passes, mark Phase 0 complete and move to **Phase 1: Embedded Node runtime**.
