#!/usr/bin/env bash
# Builds Roomy.app into ./build, and with --install copies it to ~/Applications and launches it.
# The executable inside keeps the Swift target name, CleanMac.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP_NAME="Roomy"
EXECUTABLE="CleanMac"
APP="$ROOT/build/$APP_NAME.app"
INSTALL_DIR="$HOME/Applications"

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/$EXECUTABLE"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXECUTABLE"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature, no App Sandbox entitlement: the app must read other tools' caches.
codesign --force --sign - --timestamp=none --options runtime "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    mkdir -p "$INSTALL_DIR"
    pkill -x "$EXECUTABLE" 2>/dev/null || true
    sleep 0.4
    if [[ -d "$INSTALL_DIR/$APP_NAME.app" ]]; then
        rm -rf "$INSTALL_DIR/$APP_NAME.previous.app"
        cp -R "$INSTALL_DIR/$APP_NAME.app" "$INSTALL_DIR/$APP_NAME.previous.app"
        echo "Backed up previous app to $INSTALL_DIR/$APP_NAME.previous.app"
    fi
    rm -rf "$INSTALL_DIR/$APP_NAME.app"
    cp -R "$APP" "$INSTALL_DIR/$APP_NAME.app"
    open "$INSTALL_DIR/$APP_NAME.app"
    echo "Installed and launched $INSTALL_DIR/$APP_NAME.app"
fi
