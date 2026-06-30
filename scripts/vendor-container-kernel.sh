#!/usr/bin/env bash
# Vendor the Linux kernel binary and vminit initfs OCI layout required by Apple Containerization 0.34.
#
# Kernel: downloads the Kata Containers 3.17.0 arm64 static bundle and extracts the container-
#   optimised vmlinux (VIRTIO built in) from opt/kata/share/kata-containers/vmlinux.container.
#   This is the same kernel apple/containerization's `make fetch-default-kernel` uses.
# initfs: exports ghcr.io/apple/containerization/vminit:0.34.0 (linux/arm64) as an OCI layout
#   using a FROM-only Dockerfile via the existing anglesite-oci docker-container buildx builder.
#
# Mirrors scripts/vendor-container-image.sh: produces gitignored, bundled app resources.
# Requires Docker (or compatible buildx) with linux/arm64 support on an Apple-Silicon Mac.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL_OUT="$ROOT/Resources/container-kernel"
INITFS_OUT="$ROOT/Resources/container-initfs"

KATA_VERSION="3.17.0"
KATA_URL="https://github.com/kata-containers/kata-containers/releases/download/${KATA_VERSION}/kata-static-${KATA_VERSION}-arm64.tar.xz"
VMINIT_IMAGE="ghcr.io/apple/containerization/vminit:0.34.0"

# ---------------------------------------------------------------------------
# Kernel
# ---------------------------------------------------------------------------
echo "=== Vendoring Linux kernel (Kata Containers ${KATA_VERSION}) ==="

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

KATA_ARCHIVE="$TMP/kata-static.tar.xz"
echo "Downloading ${KATA_URL} (~290 MB)…"
curl -fL --progress-bar -o "$KATA_ARCHIVE" "$KATA_URL"

echo "Inspecting tar layout (looking for vmlinux.container)…"
# The kata bundle is rooted at ./; list to find the kernel symlink path.
SYMLINK_TAR_PATH="$(tar -tf "$KATA_ARCHIVE" | grep 'vmlinux\.container$' | head -1)"
if [[ -z "$SYMLINK_TAR_PATH" ]]; then
    echo "ERROR: vmlinux.container not found in archive" >&2
    exit 1
fi
echo "Found kernel symlink at: ${SYMLINK_TAR_PATH}"

# Extract just the symlink entry first to discover what it points to.
tar -xf "$KATA_ARCHIVE" -C "$TMP" "$SYMLINK_TAR_PATH"
SYMLINK_PATH="$TMP/$SYMLINK_TAR_PATH"
SYMLINK_TARGET="$(readlink "$SYMLINK_PATH")"
if [[ -z "$SYMLINK_TARGET" ]]; then
    # Not a symlink — extract was the real file.
    ACTUAL_TAR_PATH="$SYMLINK_TAR_PATH"
else
    echo "Symlink target: ${SYMLINK_TARGET}"
    KERNEL_DIR="$(dirname "$SYMLINK_TAR_PATH")"
    ACTUAL_TAR_PATH="${KERNEL_DIR}/${SYMLINK_TARGET}"
    echo "Extracting actual kernel: ${ACTUAL_TAR_PATH}"
    tar -xf "$KATA_ARCHIVE" -C "$TMP" "$ACTUAL_TAR_PATH"
fi

# Preserve the committed .gitkeep; wipe any stale kernel.
find "$KERNEL_OUT" -mindepth 1 -not -name '.gitkeep' -delete 2>/dev/null || true

# Copy the real (dereferenced) kernel file. We may have either the symlink
# pointing at the versioned file, or the versioned file directly extracted above.
ACTUAL_PATH="$TMP/$ACTUAL_TAR_PATH"
if [[ -L "$ACTUAL_PATH" ]]; then
    cp -L "$ACTUAL_PATH" "$KERNEL_OUT/vmlinux"
else
    cp "$ACTUAL_PATH" "$KERNEL_OUT/vmlinux"
fi
echo "Kernel copied → $KERNEL_OUT/vmlinux"

# Basic sanity: must be non-trivially large (the Kata arm64 VM-optimized kernel is ~14 MB —
# smaller than a general-purpose kernel; the 1 MiB floor below just catches truncation/zero-byte).
KERNEL_SIZE=$(stat -f%z "$KERNEL_OUT/vmlinux" 2>/dev/null || stat -c%s "$KERNEL_OUT/vmlinux")
if [[ "$KERNEL_SIZE" -lt 1048576 ]]; then
    echo "ERROR: vmlinux is suspiciously small (${KERNEL_SIZE} bytes) — extraction may have failed" >&2
    exit 1
fi
echo "Kernel size: ${KERNEL_SIZE} bytes ($(( KERNEL_SIZE / 1048576 )) MiB)"
file "$KERNEL_OUT/vmlinux" || true

# ---------------------------------------------------------------------------
# initfs OCI layout
# ---------------------------------------------------------------------------
echo ""
echo "=== Vendoring vminit initfs (${VMINIT_IMAGE}) ==="

# Guard: create the anglesite-oci buildx builder only if it doesn't already exist (idempotent).
# Do not make it the global active builder; pass --builder on the build below so this script does
# not leave the developer's Docker environment changed after it exits.
if ! docker buildx inspect anglesite-oci >/dev/null 2>&1; then
    echo "Creating docker-container builder 'anglesite-oci'…"
    docker buildx create --name anglesite-oci --driver docker-container
fi

# Wipe stale layout but preserve .gitkeep.
find "$INITFS_OUT" -mindepth 1 -not -name '.gitkeep' -delete 2>/dev/null || true
mkdir -p "$INITFS_OUT"

INITFS_ARCHIVE="$TMP/initfs.tar"
echo "Exporting OCI layout from ${VMINIT_IMAGE} (linux/arm64)…"
docker buildx build \
    --builder anglesite-oci \
    --platform linux/arm64 \
    --output "type=oci,dest=${INITFS_ARCHIVE}" \
    - <<<"FROM ${VMINIT_IMAGE}"

echo "Untarring OCI layout → ${INITFS_OUT}"
tar -xf "$INITFS_ARCHIVE" -C "$INITFS_OUT"
rm -f "$INITFS_ARCHIVE"

# Verify the OCI layout is structurally valid.
for f in oci-layout index.json blobs/sha256; do
    if [[ ! -e "$INITFS_OUT/$f" ]]; then
        echo "ERROR: OCI layout missing required entry: $f" >&2
        # Fall back to skopeo if available. NOTE: this recovery path is only hit if the buildx
        # OCI export above fails to produce a valid layout. The `oci:dir:tag` form skopeo writes
        # is a tagged single-entry index; it has not been exercised against the Containerization
        # initfs loader, so if you ever land here, verify the produced layout boots before relying on it.
        if command -v skopeo >/dev/null 2>&1; then
            echo "Falling back to skopeo…"
            find "$INITFS_OUT" -mindepth 1 -not -name '.gitkeep' -delete 2>/dev/null || true
            skopeo copy \
                --override-os linux \
                --override-arch arm64 \
                "docker://${VMINIT_IMAGE}" \
                "oci:${INITFS_OUT}:vminit"
            echo "skopeo copy succeeded."
        else
            echo "ERROR: skopeo not available. Install via 'brew install skopeo' and re-run." >&2
            exit 1
        fi
        break
    fi
done

# Final verification.
echo ""
echo "=== Verification ==="
echo "Kernel:"
ls -la "$KERNEL_OUT/"
file "$KERNEL_OUT/vmlinux" || true

echo ""
echo "initfs OCI layout:"
ls -la "$INITFS_OUT/"
ls "$INITFS_OUT/blobs/sha256/" | head -5
echo "($(ls "$INITFS_OUT/blobs/sha256/" | wc -l | tr -d ' ') blobs total)"

echo ""
echo "Done. Resources/container-kernel/ and Resources/container-initfs/ are populated."
