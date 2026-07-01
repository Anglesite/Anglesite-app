#!/usr/bin/env bash
#
# Inventory the host-side embedded Node apparatus that must disappear for #70.
#
# Default mode is informational and exits 0 while the transitional host runtime still exists.
# Use --expect-retired once both container runtimes are proven; that mode fails if any tracked
# host-Node dependency remains in build config or source.

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
check_pattern "Xcode project vendors node-runtime resources" "project.yml" "Resources/node-runtime"
check_pattern "Xcode project vendors Node during build" "project.yml" "Vendor Node runtime"
check_pattern "Xcode project re-signs bundled Node" "project.yml" "Re-sign bundled Node"
check_pattern "Swift resolves bundled Node" "Sources/AnglesiteCore/NodeRuntime.swift" "node-runtime"
check_pattern "Swift host subprocess runtime remains" "Sources/AnglesiteCore/LocalSiteRuntime.swift" "host-subprocess|LocalSiteRuntime"
check_pattern "Swift in-process spawn backend remains" "Sources/AnglesiteCore/InProcessBackend.swift" "Process\\("
check_pattern "MCP stdio spawn path remains" "Sources/AnglesiteCore/MCPClient.swift" "start\\(executable:"

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
