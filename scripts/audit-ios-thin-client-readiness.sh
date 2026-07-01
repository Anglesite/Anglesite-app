#!/usr/bin/env bash
#
# Inventory the platform seams that must be resolved before #71 can add the iOS thin client.
#
# Default mode is informational and exits 0 while the app/package are still macOS-only.
# Use --expect-ready when the iOS target is being wired; that mode fails if any tracked
# blocker remains.

set -euo pipefail

MODE="inventory"
if [[ "${1:-}" == "--expect-ready" ]]; then
    MODE="expect-ready"
elif [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    cat <<'USAGE'
Usage: scripts/audit-ios-thin-client-readiness.sh [--expect-ready]

Default mode prints the remaining iOS thin-client blockers and exits 0.
--expect-ready exits non-zero when any tracked blocker remains.
USAGE
    exit 0
elif [[ $# -gt 0 ]]; then
    echo "unknown argument: $1" >&2
    exit 2
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$REPO_ROOT"

declare -a BLOCKERS=()
declare -a READY=()

blocker() {
    local label="$1"
    local detail="$2"
    BLOCKERS+=("$label -> $detail")
}

ready() {
    local label="$1"
    READY+=("$label")
}

path_exists() {
    [[ -e "$1" ]]
}

pattern_exists() {
    local path="$1"
    local pattern="$2"
    [[ -e "$path" ]] && rg -q "$pattern" "$path"
}

writing_tools_assignment_is_mac_gated() {
    local path="$1"
    [[ -e "$path" ]] || return 1
    awk '
        /public static func enableWritingTools/ {
            inFunction = 1
            braceDepth = 0
            sawAssignment = 0
            gatedAssignment = 0
            ungatedAssignment = 0
        }
        inFunction {
            for (i = 1; i <= length($0); i++) {
                char = substr($0, i, 1)
                if (char == "{") { braceDepth++ }
                if (char == "}") { braceDepth-- }
            }
            if ($0 ~ /^[[:space:]]*#if[[:space:]]+os\(macOS\)/) { macGuard = 1 }
            if ($0 ~ /writingToolsBehavior[[:space:]]*=/) {
                sawAssignment = 1
                if (macGuard == 1) {
                    gatedAssignment = 1
                } else {
                    ungatedAssignment = 1
                }
            }
            if ($0 ~ /^[[:space:]]*#endif/) { macGuard = 0 }
            if (braceDepth == 0) {
                inFunction = 0
                macGuard = 0
            }
        }
        END {
            exit (sawAssignment == 1 && gatedAssignment == 1 && ungatedAssignment == 0) ? 0 : 1
        }
    ' "$path"
}

if pattern_exists "Package.swift" "\\.iOS\\("; then
    ready "Swift package declares an iOS platform"
else
    blocker "Swift package is macOS-only" "Package.swift lacks an .iOS platform"
fi

if pattern_exists "project.yml" "platform: iOS"; then
    ready "XcodeGen project declares an iOS application target"
else
    blocker "No iOS app target" "project.yml has only macOS targets"
fi

if path_exists "Sources/AnglesiteIOS" && pattern_exists "Package.swift" "name: \"AnglesiteIOS\""; then
    ready "iOS shell source target exists"
else
    blocker "No iOS shell sources" "Sources/AnglesiteIOS and Package.swift lack an AnglesiteIOS target"
fi

if path_exists "Resources/Info-iOS.plist" || pattern_exists "project.yml" "INFOPLIST_FILE:.*iOS"; then
    ready "iOS Info.plist or generated plist config exists"
else
    blocker "No iOS bundle metadata" "project.yml/Resources do not define an iOS Info.plist"
fi

if writing_tools_assignment_is_mac_gated "Sources/AnglesiteBridge/WebViewBridge.swift"; then
    ready "Bridge Writing Tools behavior is macOS-gated"
else
    blocker "Bridge Writing Tools behavior is not platform-gated" "Sources/AnglesiteBridge/WebViewBridge.swift"
fi

if pattern_exists "Sources/AnglesiteBridge/WebViewBridge.swift" "NSViewRepresentable"; then
    blocker "Bridge preview wrapper is AppKit-shaped" "Sources/AnglesiteBridge/WebViewBridge.swift"
else
    ready "Bridge preview wrapper is split away from AppKit"
fi

if pattern_exists "Sources/AnglesiteCore/SiteFileWatcher.swift" "CoreServices|FSEvent"; then
    blocker "AnglesiteCore includes FSEvents file watching" "Sources/AnglesiteCore/SiteFileWatcher.swift"
else
    ready "File watching is platform-gated or split out of iOS Core"
fi

if pattern_exists "Sources/AnglesiteCore/SecurityScopedBookmark.swift" "securityScope|startAccessingSecurityScopedResource|bookmarkData"; then
    blocker "AnglesiteCore includes macOS package access bookmarks" "Sources/AnglesiteCore/SecurityScopedBookmark.swift"
else
    ready "Security-scoped bookmark code is platform-gated or split out of iOS Core"
fi

if pattern_exists "Sources/AnglesiteCore/InProcessBackend.swift" "Process\\("; then
    blocker "Host subprocess backend remains in shared Core" "Sources/AnglesiteCore/InProcessBackend.swift"
else
    ready "Shared Core has no direct host Process backend"
fi

if pattern_exists "Sources/AnglesiteCore/LocalSiteRuntime.swift" "LocalSiteRuntime|ProcessSupervisor|NodeRuntime"; then
    blocker "Local host runtime remains in shared Core" "Sources/AnglesiteCore/LocalSiteRuntime.swift"
else
    ready "Shared Core has no local host runtime dependency"
fi

if pattern_exists "Sources/AnglesiteCore/LocalContainerSiteRuntime.swift" "LocalContainerSiteRuntime|FSEventsFileWatcher"; then
    blocker "Local container runtime is still visible from shared Core" "Sources/AnglesiteCore/LocalContainerSiteRuntime.swift"
else
    ready "Local container runtime is split away from iOS Core"
fi

if pattern_exists "Sources/AnglesiteIntents/PreviewAnnotationProvider.swift" "import AppKit"; then
    blocker "AnglesiteIntents imports AppKit" "Sources/AnglesiteIntents/PreviewAnnotationProvider.swift"
else
    ready "Intents target is not AppKit-bound or is excluded from iOS"
fi

if pattern_exists "Sources/AnglesiteCore/HTTPSandboxControlClient.swift" "Used by the iOS app"; then
    ready "Remote sandbox control client exists"
else
    blocker "Remote sandbox control client missing" "Sources/AnglesiteCore/HTTPSandboxControlClient.swift"
fi

if pattern_exists "Sources/AnglesiteCore/RemoteSandboxSiteRuntime.swift" "actor RemoteSandboxSiteRuntime"; then
    ready "RemoteSandboxSiteRuntime exists"
else
    blocker "RemoteSandboxSiteRuntime missing" "Sources/AnglesiteCore/RemoteSandboxSiteRuntime.swift"
fi

echo "iOS thin-client readiness audit (#71)"
echo "Mode: $MODE"
echo

if [[ ${#READY[@]} -gt 0 ]]; then
    echo "Already in place:"
    for item in "${READY[@]}"; do
        echo "  - $item"
    done
    echo
fi

if [[ ${#BLOCKERS[@]} -eq 0 ]]; then
    echo "No tracked iOS thin-client blockers remain."
    exit 0
fi

echo "Tracked blockers still present:"
for item in "${BLOCKERS[@]}"; do
    echo "  - $item"
done

echo
echo "Count: ${#BLOCKERS[@]}"

if [[ "$MODE" == "expect-ready" ]]; then
    echo "ERROR: iOS thin-client readiness is expected, but tracked blockers remain." >&2
    exit 1
fi
