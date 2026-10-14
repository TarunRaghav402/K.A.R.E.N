#!/usr/bin/env bash
# Build a distributable K.A.R.E.N. app with its Python runtime embedded.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$REPO_ROOT/.build/package"
DIST_DIR="$REPO_ROOT/dist"
ARCH="$(uname -m)"

case "$ARCH" in
    arm64|x86_64) ;;
    *) echo "Unsupported Mac architecture: $ARCH" >&2; exit 1 ;;
esac

VENV_PY="$REPO_ROOT/sidecar/.venv/bin/python3"
if [ ! -x "$VENV_PY" ]; then
    echo "Create the build environment first: python3.13 -m venv sidecar/.venv" >&2
    exit 1
fi
PY_VER="$($VENV_PY --version 2>&1 | awk '{print $2}')"
if [[ "$PY_VER" != 3.13.* ]]; then
    echo "K.A.R.E.N. requires Python 3.13 to build its sidecar (found $PY_VER)." >&2
    exit 1
fi

cd "$REPO_ROOT"
swift build -c release

"$VENV_PY" -m PyInstaller \
    --noconfirm --clean --onefile --name KarenSidecar \
    --paths "$REPO_ROOT/sidecar" \
    --collect-all karen_sidecar \
    --collect-all websockets \
    --collect-all pydantic \
    --collect-all httpx \
    --collect-all aiosqlite \
    --collect-all dotenv \
    --distpath "$BUILD_DIR/sidecar-dist" \
    --workpath "$BUILD_DIR/pyinstaller-work" \
    --specpath "$BUILD_DIR" \
    "$REPO_ROOT/sidecar/karen_sidecar/__main__.py"

APP_BUNDLE="$BUILD_DIR/K.A.R.E.N..app"
APP_CONTENTS="$APP_BUNDLE/Contents"
rm -rf "$APP_BUNDLE" "$DIST_DIR" "$BUILD_DIR/staging"
mkdir -p "$APP_CONTENTS/MacOS" "$APP_CONTENTS/Resources" "$DIST_DIR" "$BUILD_DIR/staging"
cp "$REPO_ROOT/.build/release/KarenApp" "$APP_CONTENTS/MacOS/KarenApp"
cp "$BUILD_DIR/sidecar-dist/KarenSidecar" "$APP_CONTENTS/Resources/KarenSidecar"
chmod 755 "$APP_CONTENTS/Resources/KarenSidecar"

ICONSET_DIR="$BUILD_DIR/KarenIcon.iconset"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$REPO_ROOT/KarenApp/Resources/AppIcon/KarenIcon.png" \
        --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
    doubled=$((size * 2))
    sips -z "$doubled" "$doubled" "$REPO_ROOT/KarenApp/Resources/AppIcon/KarenIcon.png" \
        --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET_DIR" -o "$APP_CONTENTS/Resources/KarenIcon.icns"

cat > "$APP_CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>KarenApp</string>
    <key>CFBundleIdentifier</key><string>com.karen.assistant</string>
    <key>CFBundleName</key><string>K.A.R.E.N.</string>
    <key>CFBundleDisplayName</key><string>K.A.R.E.N.</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>KarenIcon</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSMicrophoneUsageDescription</key><string>K.A.R.E.N. uses the microphone for speech recognition and wake-word listening.</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>K.A.R.E.N. converts your speech to text on this Mac so it can respond to your requests.</string>
    <key>NSCameraUsageDescription</key><string>K.A.R.E.N. uses the camera only when gesture control is enabled.</string>
    <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

/usr/bin/codesign --force --deep --sign - \
    --identifier com.karen.assistant \
    --requirements '=designated => identifier "com.karen.assistant"' \
    "$APP_BUNDLE"

cp "$REPO_ROOT/README-INSTALL.txt" "$BUILD_DIR/staging/Read Me First.txt"
ditto "$APP_BUNDLE" "$BUILD_DIR/staging/K.A.R.E.N..app"
ln -s /Applications "$BUILD_DIR/staging/Applications"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" \
    "$DIST_DIR/K.A.R.E.N.-macos-${ARCH}.zip"
hdiutil create -volname "K.A.R.E.N." -srcfolder "$BUILD_DIR/staging" \
    -ov -format UDZO "$DIST_DIR/K.A.R.E.N.-macos-${ARCH}.dmg" >/dev/null

echo "Created: $DIST_DIR/K.A.R.E.N.-macos-${ARCH}.dmg"
echo "Created: $DIST_DIR/K.A.R.E.N.-macos-${ARCH}.zip"
