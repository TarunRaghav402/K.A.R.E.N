#!/usr/bin/env bash
# K.A.R.E.N. — Run Script
# Starts the Swift app (which auto-launches the Python sidecar).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Ensure the sidecar runs with the project-required Python 3.13 runtime.
VENV_PY="$REPO_ROOT/sidecar/.venv/bin/python3"
if [ ! -x "$VENV_PY" ]; then
    echo "⚠️  Python environment not found — run scripts/setup.sh first"
    exit 1
fi
PY_VER=$("$VENV_PY" --version 2>&1 | awk '{print $2}')
if [[ "$PY_VER" != 3.13.* ]]; then
    echo "⚠️  Sidecar environment uses Python $PY_VER; recreate it with Python 3.13.13 by running scripts/setup.sh"
    exit 1
fi

echo "▸ Starting K.A.R.E.N. …"
cd "$REPO_ROOT"
swift build -c release --package-path "$REPO_ROOT"

# Launch SwiftUI as a macOS app bundle so Launch Services keeps it running as a
# normal desktop app, instead of treating the SwiftPM executable as a command.
APP_BUNDLE="$REPO_ROOT/.build/release/K.A.R.E.N..app"
APP_CONTENTS="$APP_BUNDLE/Contents"
mkdir -p "$APP_CONTENTS/MacOS" "$APP_CONTENTS/Resources"
cp "$REPO_ROOT/.build/release/KarenApp" "$APP_CONTENTS/MacOS/KarenApp"

# Install the K.A.R.E.N. dot-orb mark as the Finder/Dock app icon.
ICONSET_DIR="$REPO_ROOT/.build/KarenIcon.iconset"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"
trap 'rm -rf "$ICONSET_DIR"' EXIT
ICON_PNG="$REPO_ROOT/KarenApp/Resources/AppIcon/KarenIcon.png"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_PNG" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
    doubled=$((size * 2))
    sips -z "$doubled" "$doubled" "$ICON_PNG" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET_DIR" -o "$APP_CONTENTS/Resources/KarenIcon.icns"
cat > "$APP_CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>KarenApp</string>
    <key>CFBundleIdentifier</key>
    <string>com.karen.assistant</string>
    <key>CFBundleName</key>
    <string>K.A.R.E.N.</string>
    <key>CFBundleDisplayName</key>
    <string>K.A.R.E.N.</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>KarenIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>K.A.R.E.N. uses the microphone for speech recognition and wake-word listening.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>K.A.R.E.N. converts your speech to text on this Mac so it can respond to your requests.</string>
    <key>NSCameraUsageDescription</key>
    <string>K.A.R.E.N. uses the camera only when gesture control is enabled.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Keep a stable designated requirement so macOS TCC permissions survive app
# rebuilds. Without this, ad-hoc signatures are identified by changing cdhashes
# and macOS can treat every rebuilt copy as a new app for privacy prompts.
/usr/bin/codesign --force --deep --sign - \
    --identifier com.karen.assistant \
    --requirements '=designated => identifier "com.karen.assistant"' \
    "$APP_BUNDLE"

INSTALL_BUNDLE="$HOME/Applications/K.A.R.E.N..app"
mkdir -p "$HOME/Applications"
killall KarenApp >/dev/null 2>&1 || true
# Remove the old SwiftPM-named bundle so Spotlight and Launchpad only see the
# human-facing K.A.R.E.N. app name.
OLD_APP_BUNDLE="$REPO_ROOT/.build/release/KarenApp.app"
if [ -d "$OLD_APP_BUNDLE" ]; then
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$OLD_APP_BUNDLE" || true
    rm -rf "$OLD_APP_BUNDLE"
fi
ditto "$APP_BUNDLE" "$INSTALL_BUNDLE"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$INSTALL_BUNDLE" || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALL_BUNDLE"
open -n "$INSTALL_BUNDLE"
