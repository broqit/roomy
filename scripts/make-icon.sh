#!/usr/bin/env bash
# Draws Resources/AppIcon.icns from scripts/make-icon.swift.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
PNG="$(mktemp /tmp/roomy-icon.XXXXXX.png)"
ICONSET="$(mktemp -d /tmp/roomy-iconset.XXXXXX.iconset)"
trap 'rm -f "$PNG"; rm -rf "$ICONSET"' EXIT

swift "$ROOT/scripts/make-icon.swift" "$PNG"
sips -z 16 16 "$PNG" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32 "$PNG" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$PNG" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64 "$PNG" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$PNG" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256 "$PNG" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$PNG" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512 "$PNG" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$PNG" --out "$ICONSET/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$PNG" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"
echo "Built $ROOT/Resources/AppIcon.icns"
