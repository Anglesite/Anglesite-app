#!/usr/bin/env zsh
#
# Scaffold a new Anglesite site by copying the template into the target directory.
#
# Usage: scaffold.sh [--yes] <target-dir>
#
# --yes  Skip interactive confirmation (used by the app's SiteScaffolder).

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${(%):-%x}")" && pwd)
TEMPLATE_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

YES=false
TARGET=""

for arg in "$@"; do
    case "$arg" in
        --yes) YES=true ;;
        *) TARGET="$arg" ;;
    esac
done

if [[ -z "$TARGET" ]]; then
    echo "Usage: scaffold.sh [--yes] <target-dir>" >&2
    exit 1
fi

if [[ "$YES" != true ]]; then
    echo "Will scaffold a new Anglesite site in: $TARGET"
    echo -n "Continue? [y/N] "
    read -r reply
    [[ "$reply" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
fi

mkdir -p "$TARGET"

# Copy the template tree, excluding scaffold infrastructure and dev-only files.
rsync -a \
    --exclude='scripts/scaffold.sh' \
    --exclude='scripts/themes.ts' \
    --exclude='scripts/*.test.ts' \
    --exclude='integrations/' \
    --exclude='node_modules/' \
    --exclude='.DS_Store' \
    "$TEMPLATE_ROOT/" "$TARGET/"

# Stamp the scaffolded site with the Anglesite version.
VERSION="1.0.0"
echo "ANGLESITE_VERSION=$VERSION" > "$TARGET/.site-config"

echo "==> Scaffolded Anglesite site in $TARGET"
