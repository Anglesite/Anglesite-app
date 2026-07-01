#!/usr/bin/env bash
#
# Inventory the host-side embedded Node apparatus that must disappear for #70.
#
# Default mode is informational and exits 0. Use --expect-retired in the #70 branch; that
# mode fails if any tracked bundled Node, npm cache, or host preview runtime dependency
# remains in build config or source.

set -euo pipefail

MODE="inventory"
if [[ "${1:-}" == "--expect-retired" ]]; then
    MODE="expect-retired"
elif [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    cat <<'USAGE'
Usage: scripts/audit-host-node-retirement.sh [--expect-retired]

Default mode prints the remaining host-side Node dependencies and exits 0.
--expect-retired exits non-zero when any tracked dependency remains.
USAGE
    exit 0
elif [[ $# -gt 0 ]]; then
    echo "unknown argument: $1" >&2
    exit 2
fi

# rg is load-bearing: check_pattern runs it inside an `if` condition, where a missing
# ripgrep reads as "no match" and biases --expect-retired toward a false pass. Fail loudly.
if ! command -v rg >/dev/null 2>&1; then
    echo "error: ripgrep (rg) not found on PATH — install it (brew install ripgrep) and re-run." >&2
    exit 3
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$REPO_ROOT"

declare -a FINDINGS=()

check_path() {
    local label="$1"
    local path="$2"
    if [[ -e "$path" ]]; then
        FINDINGS+=("$label -> $path")
    fi
}

check_pattern() {
    local label="$1"
    local path="$2"
    local pattern="$3"
    if [[ -e "$path" ]] && rg -q "$pattern" "$path"; then
        FINDINGS+=("$label -> $path")
    fi
}

check_path "Node vendor script" "scripts/vendor-node.sh"
check_path "Node re-sign script" "scripts/resign-node.sh"
check_path "Primed npm cache vendor script" "scripts/vendor-npm-cache.sh"
check_path "Bundled Node entitlements" "Resources/node-runtime.entitlements"
check_path "Primed npm cache resource" "Resources/npm-cache"
check_path "Bundled Node resource" "Resources/node-runtime"
check_pattern "Xcode project vendors node-runtime resources" "project.yml" "Resources/node-runtime"
check_pattern "Xcode project vendors npm-cache resources" "project.yml" "Resources/npm-cache"
check_pattern "Xcode project vendors Node during build" "project.yml" "Vendor Node runtime"
check_pattern "Xcode project vendors npm cache during build" "project.yml" "Vendor primed npm cache"
check_pattern "Xcode project re-signs bundled Node" "project.yml" "Re-sign bundled Node"
check_pattern "Swift resolves bundled Node" "Sources/AnglesiteCore/NodeRuntime.swift" "node-runtime"
check_pattern "Swift npm cache extractor remains" "Sources/AnglesiteCore/NodeModulesCache.swift" "NodeModulesCache|npm-cache"
check_pattern "Swift Astro dev-server supervisor remains" "Sources/AnglesiteCore/AstroDevServer.swift" "AstroDevServer|astro dev"
check_pattern "Swift host preview runtime remains" "Sources/AnglesiteCore/LocalSiteRuntime.swift" "host-subprocess|LocalSiteRuntime"

echo "Host Node retirement audit (#70)"
echo "Mode: $MODE"
echo

if [[ ${#FINDINGS[@]} -eq 0 ]]; then
    echo "No tracked host-side Node dependencies remain."
    exit 0
fi

echo "Tracked host-side Node dependencies still present:"
for finding in "${FINDINGS[@]}"; do
    echo "  - $finding"
done

echo
echo "Count: ${#FINDINGS[@]}"

if [[ "$MODE" == "expect-retired" ]]; then
    echo "ERROR: host Node retirement is expected, but tracked dependencies remain." >&2
    exit 1
fi
