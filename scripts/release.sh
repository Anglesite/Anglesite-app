#!/usr/bin/env bash
# Release pipeline driver. Stubbed until the steady state is settled — for now this script
# prints the checklist documented in docs/release.md and exits non-zero so it can't be
# mistaken for a real automation hook.
#
# See `docs/release.md` for the full background. The intended end state is:
#
#   ./scripts/release.sh 0.2.0
#     1. Bump MARKETING_VERSION
#     2. xcodegen generate
#     3. xcodebuild archive -> exportArchive (Developer ID signed)
#     4. xcrun notarytool submit … --wait
#     5. xcrun stapler staple
#     6. sign_update (Sparkle) -> signature + length
#     7. Regenerate appcast.xml entry
#     8. Upload artifacts to anglesite.dev (or GitHub Releases)

set -euo pipefail

cat <<'EOF'
🚧  scripts/release.sh is a stub.

Until this is wired up to CI, follow the per-release checklist in
docs/release.md. The one-time Sparkle key-generation step lives in
the same doc.

This stub exits non-zero so CI can't silently no-op a release.
EOF

exit 1
