#!/bin/bash
# Derive every Mac icon representation from the iPhone/iPad artwork.
set -euo pipefail
cd "$(dirname "$0")/.."
source_icon="App/MobileAssets.xcassets/AppIcon.appiconset/AppIcon.png"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
iconset="$temporary/AppIcon.iconset"
mkdir -p "$iconset"
for points in 16 32 128 256 512; do
  for scale in 1 2; do
    pixels=$((points * scale))
    suffix=""
    if [[ "$scale" == 2 ]]; then suffix="@2x"; fi
    output="$iconset/icon_${points}x${points}${suffix}.png"
    if [[ "$pixels" == 1024 ]]; then
      cp "$source_icon" "$output"
    else
      sips -z "$pixels" "$pixels" "$source_icon" --out "$output" >/dev/null
    fi
  done
done
iconutil -c icns "$iconset" -o App/AppIcon.icns
