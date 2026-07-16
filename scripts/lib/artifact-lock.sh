#!/usr/bin/env bash
# Read/write helpers for scripts/container-artifact-versions.lock.json — the pinned
# kernel/initfs artifact versions and digests recorded for #616 (distribution-grade,
# reproducible container artifact provisioning). Source this file; callers own their own
# comparison/severity policy (a fresh vendor always hard-fails on mismatch, the build-time
# guard follows its existing Debug-warn/Release-error convention) — this file is pure I/O.

ARTIFACT_LOCK_FILE="${ARTIFACT_LOCK_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/container-artifact-versions.lock.json}"

ensure_jq() {
    command -v jq >/dev/null 2>&1 || {
        echo "ERROR: jq not found on PATH — required to read $ARTIFACT_LOCK_FILE. Install via 'brew install jq'." >&2
        exit 1
    }
}

# lock_get '.kata.tarball_sha256' -> prints the value, or the literal string "null" if unset.
lock_get() {
    ensure_jq
    jq -r "$1 // \"null\"" "$ARTIFACT_LOCK_FILE"
}

# lock_set '.kata.tarball_sha256' 'abc123...' -> writes the value in place.
lock_set() {
    ensure_jq
    local tmp
    tmp="$(mktemp)"
    jq --arg v "$2" "$1 = \$v" "$ARTIFACT_LOCK_FILE" >"$tmp" && mv "$tmp" "$ARTIFACT_LOCK_FILE"
}

sha256_of() {
    # macOS ships `shasum` (Perl, always present) but not GNU `sha256sum` by default; prefer the
    # latter when present (Linux/CI, and faster on large files) and fall back otherwise.
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}
