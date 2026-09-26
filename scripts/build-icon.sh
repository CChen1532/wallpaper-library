#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output="${1:-Resources/AppIcon.icns}"
work="$(mktemp -d "${TMPDIR:-/tmp}/wallpaper-icon.XXXXXX")"
trap 'rm -rf "$work"' EXIT
iconset="$work/AppIcon.iconset"
mkdir -p "$iconset"
# Keep the generated alpha; only resample for the standard macOS representations.
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Resources/AppIcon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    sips -z "$retina" "$retina" Resources/AppIcon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$output"
