#!/usr/bin/env bash
# Generate Sparkle appcast.xml from GitHub Releases.
#
# Each release's body is expected to contain machine-readable markers added by
# `scripts/release.sh`:
#
#   <!-- sparkle-version: 1 -->
#   <!-- sparkle-shortVersionString: 0.2.0 -->
#   <!-- sparkle-edSignature: ABC123... -->
#   <!-- sparkle-length: 12345678 -->
#   <!-- sparkle-minimumSystemVersion: 14.0 -->
#
# Drafts and prereleases are skipped. The enclosure URL points at the .zip asset
# uploaded to the GitHub Release.
#
# Usage:
#   scripts/generate-appcast.sh > build/appcast.xml
#   scripts/generate-appcast.sh build/appcast.xml
set -euo pipefail

out_path="${1:-/dev/stdout}"

command -v gh >/dev/null \
  || { echo "error: gh CLI not installed" >&2; exit 1; }
command -v jq >/dev/null \
  || { echo "error: jq not installed (brew install jq)" >&2; exit 1; }

repo="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
feed_url="https://anglesite.dev/appcast.xml"

# Pull every non-draft, non-prerelease release in descending publish order.
releases_json="$(gh release list --limit 100 --json tagName,name,createdAt,isDraft,isPrerelease,publishedAt 2>/dev/null)"

# Extract a marker value from a release body. Returns empty string if absent.
marker() {
  local body="$1" key="$2"
  printf '%s\n' "$body" | sed -n "s|.*<!-- sparkle-${key}: \\([^>]*\\) -->.*|\\1|p" | head -1 | sed 's/[[:space:]]*$//'
}

# Convert ISO 8601 to RFC 822 (Sparkle requires RFC 822 in pubDate).
iso_to_rfc822() {
  local iso="$1"
  # macOS date: ISO 8601 input with -j -f
  date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$iso" "+%a, %d %b %Y %H:%M:%S +0000" 2>/dev/null \
    || echo "$iso"
}

emit_header() {
  cat <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Anglesite</title>
    <link>${feed_url}</link>
    <description>Most recent updates to Anglesite.</description>
    <language>en</language>
EOF
}

emit_footer() {
  cat <<'EOF'
  </channel>
</rss>
EOF
}

emit_item() {
  local tag="$1"
  local name="$2"
  local pub_date="$3"
  local version="$4"
  local short_version="$5"
  local signature="$6"
  local length="$7"
  local min_system="$8"
  local zip_url="https://github.com/${repo}/releases/download/${tag}/Anglesite-${short_version}.zip"
  local title_text="${name:-$tag}"
  cat <<EOF
    <item>
      <title>${title_text}</title>
      <pubDate>${pub_date}</pubDate>
      <sparkle:version>${version}</sparkle:version>
      <sparkle:shortVersionString>${short_version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${min_system}</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/${repo}/releases/tag/${tag}</sparkle:releaseNotesLink>
      <enclosure
        url="${zip_url}"
        sparkle:edSignature="${signature}"
        length="${length}"
        type="application/octet-stream" />
    </item>
EOF
}

{
  emit_header

  # Iterate releases newest-first; for each, fetch body and parse markers.
  echo "$releases_json" | jq -c '.[] | select(.isDraft == false and .isPrerelease == false)' \
    | while read -r entry; do
      tag="$(echo "$entry" | jq -r '.tagName')"
      name="$(echo "$entry" | jq -r '.name')"
      published="$(echo "$entry" | jq -r '.publishedAt // .createdAt')"
      body="$(gh release view "$tag" --json body -q .body)"

      version="$(marker "$body" version)"
      short_version="$(marker "$body" shortVersionString)"
      signature="$(marker "$body" edSignature)"
      length="$(marker "$body" length)"
      min_system="$(marker "$body" minimumSystemVersion)"
      min_system="${min_system:-14.0}"

      if [[ -z "$version" || -z "$short_version" || -z "$signature" || -z "$length" ]]; then
        echo "warning: skipping release $tag — missing sparkle-* markers in body" >&2
        continue
      fi

      pub_date="$(iso_to_rfc822 "$published")"
      emit_item "$tag" "$name" "$pub_date" "$version" "$short_version" "$signature" "$length" "$min_system"
    done

  emit_footer
} > "$out_path"

if [[ "$out_path" != "/dev/stdout" ]]; then
  echo "wrote appcast → $out_path" >&2
fi
