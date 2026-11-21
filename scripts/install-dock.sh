#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_APP="$ROOT_DIR/build/RufusMac.app"
DEST_APP="/Applications/RufusMac.app"

if [ ! -d "$SRC_APP" ]; then
    echo "Error: $SRC_APP not found. Run scripts/build-app.sh first." >&2
    exit 1
fi

echo "==> Installing RufusMac.app to /Applications..."
rm -rf "$DEST_APP"
cp -R "$SRC_APP" "$DEST_APP"
xattr -dr com.apple.quarantine "$DEST_APP" 2>/dev/null || true

# Register with LaunchServices so Finder / Dock sees the new icon immediately
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST_APP" 2>/dev/null || true

echo "==> Pinning RufusMac.app to macOS Dock..."
if defaults read com.apple.dock persistent-apps | grep -q "RufusMac.app"; then
    echo "    RufusMac.app is already pinned in the Dock."
else
    defaults write com.apple.dock persistent-apps -array-add \
        "<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>file:///Applications/RufusMac.app/</string><key>_CFURLStringType</key><integer>15</integer></dict></dict></dict>"
    echo "    Added RufusMac.app to Dock persistent-apps."
fi

killall Dock 2>/dev/null || true
echo "==> Done! RufusMac is installed in /Applications and pinned to your Dock."
