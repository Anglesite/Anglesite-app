#!/usr/bin/env bash
#
# Creates a smoke-test Anglesite site at ~/Sites/anglesite-smoke/, populated
# from the in-repo template (Resources/Template/) with `node_modules` installed.
#
# Use this fixture to manually verify the dev-server lifecycle end-to-end:
# PreviewModel → AstroDevServer → ProcessSupervisor → window-close teardown.
# The template alone (without node_modules) leaves the preview in `.failed`
# and never exercises the subprocess code path.
#
# Idempotent: re-running mirrors any template changes and runs `npm install`
# incrementally.

set -euo pipefail

# --mas: also build the sandboxed Mac App Store target, real-signed (Apple Development),
# so the run exercises the App Sandbox + hardened-runtime Node re-sign — the load-bearing
# Phase 10.1 Task 11 validation. Without it, this preps the DevID fixture only.
MAS=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mas) MAS=1; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

TEMPLATE_SRC="$REPO_ROOT/Resources/Template"
FIXTURE_DIR="$HOME/Sites/anglesite-smoke"

if [[ ! -d "$TEMPLATE_SRC" ]]; then
    echo "error: template not found at $TEMPLATE_SRC" >&2
    echo "       Resources/Template/ should be committed to the app repo." >&2
    exit 1
fi

mkdir -p "$HOME/Sites"

echo "==> mirroring $TEMPLATE_SRC → $FIXTURE_DIR"
# Skip node_modules and build outputs in the mirror so the existing install
# stays put and the npm install below is incremental rather than full.
rsync -a \
    --exclude='node_modules/' \
    --exclude='.astro/' \
    --exclude='dist/' \
    --exclude='.wrangler/' \
    "$TEMPLATE_SRC/" "$FIXTURE_DIR/"

# Prefer the vendored Node runtime when available — that's what the running
# app uses, so it's the most accurate smoke environment. Fall back to PATH npm
# when the vendor step hasn't been run yet.
if [[ -x "$REPO_ROOT/Resources/node-runtime/bin/npm" ]]; then
    NPM="$REPO_ROOT/Resources/node-runtime/bin/npm"
    PATH="$REPO_ROOT/Resources/node-runtime/bin:$PATH"
    echo "==> using vendored node runtime"
else
    NPM=npm
    echo "==> using PATH npm (run scripts/vendor-node.sh for the vendored runtime)"
fi

cd "$FIXTURE_DIR"
echo "==> $NPM install --no-audit --no-fund --prefer-offline"
"$NPM" install --no-audit --no-fund --prefer-offline

if [[ $MAS -eq 0 ]]; then
cat <<EOF

✓ Smoke fixture ready: $FIXTURE_DIR

  Verify the dev-server lifecycle (Developer ID build):
    1. Launch Anglesite (or use 'open Anglesite.xcodeproj' + ⌘R from Xcode).
    2. Open Folder… → pick anglesite-smoke (or it'll appear in the launcher
       since ~/Sites/anglesite-smoke is under the default sitesRoot).
    3. Preview should reach .ready and a node child should be parented by
       the app: ps -A -o pid,ppid,comm | awk '\$2 == <anglesite-pid>'
    4. Close the SiteWindow — the node child should be reaped within a few
       seconds (ProcessSupervisor.shutdownAll path).
    5. Click the gray health-badge dot left of the Chat button → popover opens
       titled "Health unknown". Click "Recheck" → spinner appears, settles to
       a green/yellow/red dot depending on what the scan finds. The popover
       summary should match what /anglesite:check reports for the same site.
    6. Quit the app — no orphan node processes should remain.
EOF
    exit 0
fi

# ----- MAS variant: real-signed sandbox validation (Task 11) -----
# A real Apple Development identity is required — the App Sandbox + hardened-runtime
# Node JIT entitlements are NOT enforced under ad-hoc signing, so an ad-hoc run would
# pass for the wrong reasons. Bail early with guidance if no identity is present.
if ! security find-identity -v -p codesigning | grep -q "Apple Development"; then
    echo "error: no 'Apple Development' signing identity found." >&2
    echo "       Task 11 needs a real cert (Xcode → Settings → Accounts → add Apple ID)." >&2
    echo "       'security find-identity -v -p codesigning' must list ≥1 identity." >&2
    exit 1
fi

# Manual signing with the Apple Development identity + team — no provisioning profile needed
# for a local development run (Automatic style would try to fetch one and fail offline). Derive
# the 10-char Team ID from the cert; override with DEVELOPMENT_TEAM=... if the default is wrong.
DEV_TEAM="${DEVELOPMENT_TEAM:-$(security find-certificate -c "Apple Development" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null | grep -oE 'OU *= *[A-Z0-9]{10}' | grep -oE '[A-Z0-9]{10}' | head -1)}"
if [[ -z "$DEV_TEAM" ]]; then
    echo "error: couldn't derive the Apple Development Team ID; set DEVELOPMENT_TEAM=..." >&2
    exit 1
fi

DERIVED="$REPO_ROOT/build/mas-smoke"
echo "==> building AnglesiteMAS (real-signed: Apple Development, team $DEV_TEAM) into $DERIVED"
xcodebuild -project "$REPO_ROOT/Anglesite.xcodeproj" \
    -scheme AnglesiteMAS -configuration Debug \
    -derivedDataPath "$DERIVED" \
    CODE_SIGN_IDENTITY="Apple Development" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$DEV_TEAM" \
    build 2>&1 | tail -3

APP="$DERIVED/Build/Products/Debug/AnglesiteMAS.app"
NODE="$APP/Contents/Resources/node-runtime/bin/node"
echo "==> verifying the bundled Node is real-signed with our team + JIT/sandbox entitlements"
codesign -dv --verbose=4 "$NODE" 2>&1 | grep -E "Authority=Apple Development|TeamIdentifier|flags=" || true
codesign -d --entitlements :- "$NODE" 2>/dev/null | plutil -p - 2>/dev/null | grep -E "app-sandbox|allow-jit|inherit|disable-library-validation" || true

cat <<EOF

✓ MAS smoke fixture ready: $FIXTURE_DIR
✓ Real-signed MAS app built: $APP

  This is the load-bearing Phase 10.1 validation — it must run INTERACTIVELY
  under the real signature (the sandbox/JIT entitlements aren't enforced ad-hoc).

  Launch the built app from a normal location (signed sandboxed apps refuse to
  run from /private/tmp):
    cp -R "$APP" ~/Applications/ && open -n ~/Applications/AnglesiteMAS.app

  Then exercise the WRITE-HEAVY loop and watch for sandbox denials
  (log stream --predicate 'eventMessage CONTAINS "deny"' --style compact):
    1. Open Folder… → pick anglesite-smoke. This Powerbox grant is the per-site
       security-scoped grant (do NOT pre-inject a bookmark — a foreign process's
       scoped bookmark won't resolve in the app; cf. spike 6.5). It persists for
       next launch.
    2. Preview should reach .ready — Astro dev writes .astro/ and serves :4321.
       A node child must be parented by the app (ps -o pid,ppid,comm).
    3. Deploy button → 'npm run build' must write dist/ inside the granted folder,
       then the pre-deploy scan runs. (A real 'wrangler deploy' needs a Cloudflare
       token; reaching the wrangler spawn is the in-sandbox signal.)
    4. Drag an image onto an <img> in the preview → bytes write to
       public/images/ and sharp runs. THIS is where cs.disable-library-validation
       is exercised: if the optimized variants appear, sharp's native addon loaded
       under hardened runtime → the entitlement is doing its job. If the drop fails
       with a code-signing/library-validation error in the log, record it.
    5. Close the window → node child reaped. Quit → no orphan node.
    6. Chat button must be ABSENT (compiled out of MAS); Settings → no GitHub
       Connect row, no 'Check for Updates…' menu item.

  Capture PASS/FAIL per step (esp. #3 wrangler-spawn and #4 sharp) in a notes
  file; this is the evidence that settles cs.disable-library-validation and the
  in-sandbox write path.
EOF
