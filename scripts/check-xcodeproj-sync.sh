#!/usr/bin/env bash
# Guards against project.yml ↔ source-tree drift for the gitignored Anglesite.xcodeproj.
#
# Anglesite.xcodeproj/ is regenerated from project.yml via XcodeGen and never committed,
# so a stale or malformed spec never fails `swift build` CI — it only surfaces later as
# `error: cannot find 'X' in scope` from `xcodebuild` on a contributor's machine (#123).
#
# This check regenerates the project, then asserts that every application target actually
# *compiles* every Swift file under Sources/AnglesiteApp. It catches the drift modes CI can
# see on a fresh generate:
#   1. A malformed/typo'd path in project.yml — XcodeGen exits non-zero on spec validation.
#   2. A narrowed/removed `sources:` entry that silently drops files from a target's compile
#      phase — XcodeGen exits 0, but the dropped files are then absent from that target's
#      Sources build phase (this script fails, naming the target and files).
#
# Membership is checked per target (via the target's PBXSourcesBuildPhase), not by mere
# presence of a file reference — because both the Anglesite and AnglesiteMAS targets share
# Sources/AnglesiteApp, a file dropped from one but kept by the other would otherwise slip by.
#
# It deliberately does NOT run a full `xcodebuild` of the app: the app target needs the
# macOS 27 SDK (Xcode 27), which CI runners don't yet ship (see #128). XcodeGen only needs
# the spec + sources, so this guard runs anywhere xcodegen + python3 are installed.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen not found on PATH." >&2
  echo "       Install with: brew install xcodegen" >&2
  exit 1
fi

# The app target's `sources:` root in project.yml. The AnglesiteCore/Bridge/Intents trees are
# SwiftPM package products (compiled by SwiftPM, not file-referenced in the pbxproj), so only
# this app-target tree is verifiable against the generated project.
sources_root="Sources/AnglesiteApp"

# Regenerate the project. A spec-validation error (e.g. a path typo) exits non-zero here and
# `set -e` aborts. --quiet suppresses the success banner but still emits warnings/errors.
echo "Regenerating Anglesite.xcodeproj via xcodegen…"
xcodegen generate --quiet

pbxproj="Anglesite.xcodeproj/project.pbxproj"
if [[ ! -f "$pbxproj" ]]; then
  echo "error: $pbxproj not found after xcodegen generate." >&2
  exit 1
fi

# Resolve, per application target, the set of Swift files it compiles, and compare against the
# Swift files on disk under $sources_root. plutil reads the old-style pbxproj plist; python3
# walks the object graph (target → PBXSourcesBuildPhase → PBXBuildFile → PBXFileReference).
plutil -convert json -o /tmp/anglesite-pbxproj.json "$pbxproj"

python3 - "$sources_root" /tmp/anglesite-pbxproj.json <<'PY'
import json, os, sys

sources_root, pbx_json = sys.argv[1], sys.argv[2]

on_disk = {
    f for _root, _dirs, files in os.walk(sources_root)
    for f in files if f.endswith(".swift")
}
if not on_disk:
    sys.exit(f"error: no .swift files found under {sources_root} — is the working tree intact?")

objects = json.load(open(pbx_json))["objects"]
app_targets = [
    v for v in objects.values()
    if v.get("isa") == "PBXNativeTarget"
    and v.get("productType") == "com.apple.product-type.application"
]
if not app_targets:
    sys.exit("error: no application targets found in the generated project.")

failed = False
for target in sorted(app_targets, key=lambda t: t["name"]):
    compiled = set()
    for phase_id in target.get("buildPhases", []):
        phase = objects.get(phase_id, {})
        if phase.get("isa") != "PBXSourcesBuildPhase":
            continue
        for build_file_id in phase.get("files", []):
            ref = objects.get(objects.get(build_file_id, {}).get("fileRef", ""), {})
            path = ref.get("path", "")
            if path.endswith(".swift"):
                compiled.add(os.path.basename(path))

    missing = sorted(on_disk - compiled)
    if missing:
        failed = True
        print(
            f"error: target '{target['name']}' does not compile {len(missing)} file(s) that "
            f"exist under {sources_root}.", file=sys.stderr)
        print(
            "       project.yml's sources have drifted from disk; an xcodebuild of this target "
            "would fail with 'cannot find … in scope':", file=sys.stderr)
        for f in missing:
            print(f"         - {sources_root}/{f}", file=sys.stderr)

if failed:
    sys.exit(1)

names = ", ".join(sorted(t["name"] for t in app_targets))
print(f"✓ Anglesite.xcodeproj is in sync: {len(on_disk)} file(s) under {sources_root} "
      f"compiled by every app target ({names}).")
PY
