#!/usr/bin/env bash
# Shared staging step for scripts that build Containers/anglesite-dev/Dockerfile (the app's
# local dev-server image), whichever tool builds it (Apple `container` CLI or podman).
#
# Stages the MCP sidecar (from the sibling plugin repo) and the website template's dependency
# manifests into the build context, and registers a cleanup trap so the staged, gitignored
# copies don't linger after the build. Source this file, then call stage_dev_image_context "$CTX".

stage_dev_image_context() {
    local ctx="$1"
    local root
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

    # Mirror scripts/copy-plugin.sh's resolution: honor $ANGLESITE_PLUGIN_SRC, default to
    # ../anglesite (sibling under the same parent dir as this repo — wrong from inside a
    # worktree, so set ANGLESITE_PLUGIN_SRC there).
    local default_plugin_src="$(cd "$root/.." && pwd)/anglesite"
    local plugin_src="${ANGLESITE_PLUGIN_SRC:-$default_plugin_src}"

    if [[ ! -d "$plugin_src" ]]; then
        echo "ERROR: plugin source not found at $plugin_src" >&2
        echo "       Set ANGLESITE_PLUGIN_SRC or clone github.com/Anglesite/anglesite as a sibling." >&2
        exit 1
    fi
    if [[ ! -f "$plugin_src/.claude-plugin/plugin.json" ]]; then
        echo "ERROR: $plugin_src does not look like the Anglesite plugin (no .claude-plugin/plugin.json)" >&2
        exit 1
    fi

    local sidecar_stage="$ctx/mcp-sidecar"
    echo "Staging MCP sidecar from $plugin_src → $sidecar_stage"
    rm -rf "$sidecar_stage"
    mkdir -p "$sidecar_stage"

    # Copy the plugin's server/ directory + package manifests (no node_modules, no .git).
    rsync -a --delete \
        --exclude='node_modules/' \
        --exclude='.git/' \
        "$plugin_src/server/" "$sidecar_stage/server/"
    cp "$plugin_src/package.json" "$sidecar_stage/"
    cp "$plugin_src/package-lock.json" "$sidecar_stage/"

    echo "Sidecar staged: $(ls "$sidecar_stage")"

    # Stage the website template's dependency manifests + the hydrate script into the build
    # context, so the image can bake the template's full node_modules (design §5b, same pattern
    # as container/Dockerfile). hydrate.sh is shared with the Cloudflare image —
    # container/hydrate.sh is the single source.
    local template_stage="$ctx/template"
    echo "Staging template manifests from $root/Resources/Template → $template_stage"
    rm -rf "$template_stage"
    mkdir -p "$template_stage"
    cp "$root/Resources/Template/package.json" "$template_stage/"
    cp "$root/Resources/Template/package-lock.json" "$template_stage/"
    cp "$root/container/hydrate.sh" "$ctx/hydrate.sh"

    # Clean up the staged sidecar + template + hydrate script on exit (success or failure) so
    # they don't accumulate in the build context. These are gitignored. The trap body is built
    # as a string with the paths substituted now — `local`s go out of scope with this function's
    # stack frame, so a trap naming them by variable (rather than value) would see them unbound
    # by the time EXIT actually fires.
    trap "rm -rf '$sidecar_stage' '$template_stage' '$ctx/hydrate.sh'" EXIT
}
