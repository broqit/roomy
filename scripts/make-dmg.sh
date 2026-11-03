#!/usr/bin/env bash
# Builds Roomy.app and packs build/Roomy-<version>.dmg.
# The window offers the app and a shortcut to /Applications.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP_NAME="Roomy"
APP="$ROOT/build/$APP_NAME.app"

"$(dirname "$0")/build-app.sh"
test -d "$APP"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$ROOT/build/${APP_NAME}-${VERSION}.dmg"
RW="$(mktemp /tmp/roomy-rw.XXXXXX.dmg)"
MOUNT="/Volumes/$APP_NAME"
BACKGROUND="$(mktemp /tmp/roomy-bg.XXXXXX.png)"
cleanup() {
    hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true
    rm -f "$RW" "$BACKGROUND"
}
trap cleanup EXIT

SIZE_KB="$(du -sk "$APP" | awk '{print $1}')"
SIZE_MB="$(( SIZE_KB / 1024 + 32 ))"
swift "$ROOT/scripts/dmg-background.swift" "$BACKGROUND"

rm -f "$RW" "$DMG"
if [[ -d "$MOUNT" ]]; then
    hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true
fi
hdiutil create -size "${SIZE_MB}m" -fs HFS+ -volname "$APP_NAME" "$RW" >/dev/null
hdiutil attach -readwrite -noverify -noautoopen -mountpoint "$MOUNT" "$RW" >/dev/null
sleep 1

cp -R "$APP" "$MOUNT/$APP_NAME.app"
ln -s /Applications "$MOUNT/Applications"
mkdir -p "$MOUNT/.background"
cp "$BACKGROUND" "$MOUNT/.background/background.png"

# Finder has to be allowed to control this Mac. Without that, the image still installs by drag.
osascript <<EOF || echo "Finder did not arrange the window. The image still contains Roomy and Applications."
tell application "Finder"
    tell disk "$APP_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {240, 140, 920, 560}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 96
        set background picture of viewOptions to file ".background:background.png"
        set position of item "$APP_NAME.app" of container window to {160, 190}
        set position of item "Applications" of container window to {500, 190}
        close
        open
        update without registering applications
        delay 1
    end tell
end tell
EOF

chmod -Rf go-w "$MOUNT" || true
sync
hdiutil detach "$MOUNT" >/dev/null
trap - EXIT
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$RW" "$BACKGROUND"
echo "Built $DMG"
