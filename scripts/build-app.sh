#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="RufusMac"
APP_BUNDLE="$ROOT_DIR/build/${APP_NAME}.app"
HELPERS_DIR="$ROOT_DIR/build/helpers"
ICONSET_DIR="$ROOT_DIR/build/AppIcon.iconset"
ICNS_PATH="$ROOT_DIR/build/AppIcon.icns"

echo "==> Step 1/5: Ensuring bundled helpers (wimlib-imagex, ms-sys)..."
bash "$ROOT_DIR/scripts/build-helpers.sh"

echo "==> Step 2/5: Building Release binaries for Intel x86_64..."
cd "$ROOT_DIR"
swift build -c release --arch x86_64 --product RufusMac
swift build -c release --arch x86_64 --product rufusmac-helper

BIN_DIR="$(swift build -c release --arch x86_64 --show-bin-path)"
echo "    Release binary dir: $BIN_DIR"

echo "==> Step 3/5: Generating macOS App Icon (.icns)..."
swift "$ROOT_DIR/scripts/generate-icon.swift" "$ICONSET_DIR"
iconutil -c icns "$ICONSET_DIR" -o "$ICNS_PATH"

echo "==> Step 4/5: Assembling ${APP_NAME}.app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Helpers"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$ROOT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$ICNS_PATH" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp "$BIN_DIR/RufusMac" "$APP_BUNDLE/Contents/MacOS/RufusMac"
cp "$BIN_DIR/rufusmac-helper" "$APP_BUNDLE/Contents/Helpers/rufusmac-helper"
cp "$HELPERS_DIR/wimlib-imagex" "$APP_BUNDLE/Contents/Helpers/wimlib-imagex"
cp "$HELPERS_DIR/ms-sys" "$APP_BUNDLE/Contents/Helpers/ms-sys"

chmod +x \
    "$APP_BUNDLE/Contents/MacOS/RufusMac" \
    "$APP_BUNDLE/Contents/Helpers/rufusmac-helper" \
    "$APP_BUNDLE/Contents/Helpers/wimlib-imagex" \
    "$APP_BUNDLE/Contents/Helpers/ms-sys"

echo "==> Step 5/5: Ad-hoc codesigning ${APP_NAME}.app..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo "==> Build complete: $APP_BUNDLE"
file "$APP_BUNDLE/Contents/MacOS/RufusMac"
ls -lh "$APP_BUNDLE/Contents/Helpers/"
