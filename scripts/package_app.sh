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
export PYINSTALLER_CONFIG_DIR="${PYINSTALLER_CONFIG_DIR:-$BUILD_DIR/pyinstaller-config}"
SWIFT_BUILD_DIR="$BUILD_DIR/swift-refresh"
SWIFT_APP_EXECUTABLE="$SWIFT_BUILD_DIR/out/Products/Release/KarenApp"
build_status=0
CLANG_MODULE_CACHE_PATH="$BUILD_DIR/swift-module-cache" swift build -c release \
    --cache-path "$BUILD_DIR/swift-cache" \
    --config-path "$BUILD_DIR/swift-config" \
    --security-path "$BUILD_DIR/swift-security" \
    --scratch-path "$SWIFT_BUILD_DIR" \
    --manifest-cache local \
    --disable-sandbox || build_status=$?

# SwiftPM can successfully link the release app but fail its optional dSYM
# generation under restricted file access. Ship the linked executable when it
# exists; fail only when there is no runnable build product.
if [ ! -x "$SWIFT_APP_EXECUTABLE" ]; then
    echo "Swift build failed before producing KarenApp (exit $build_status)." >&2
    exit "${build_status:-1}"
fi
if [ "$build_status" -ne 0 ]; then
    echo "Warning: SwiftPM couldn't generate optional debug symbols; packaging the linked release app." >&2
fi

"$VENV_PY" -m PyInstaller \
    --noconfirm --clean --onedir --name KarenSidecar \
    --paths "$REPO_ROOT/sidecar" \
    --add-data "$REPO_ROOT/sidecar/data/input_sources.json:data" \
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
cp "$SWIFT_APP_EXECUTABLE" "$APP_CONTENTS/MacOS/KarenApp"
cp -R "$BUILD_DIR/sidecar-dist/KarenSidecar" "$APP_CONTENTS/Resources/KarenSidecar"
chmod 755 "$APP_CONTENTS/Resources/KarenSidecar/KarenSidecar"

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
if iconutil -c icns "$ICONSET_DIR" -o "$APP_CONTENTS/Resources/KarenIcon.icns"; then
    :
else
    # The icon is decorative. Keep packaging even if iconutil rejects the
    # generated bitmap set on a particular macOS release.
    rm -f "$APP_CONTENTS/Resources/KarenIcon.icns"
fi

cat > "$APP_CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>KarenApp</string>
    <key>CFBundleIdentifier</key><string>com.karen.assistant</string>
    <key>CFBundleName</key><string>K.A.R.E.N.</string>
    <key>CFBundleDisplayName</key><string>K.A.R.E.N.</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
    <key>CFBundleSignature</key><string>????</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSMicrophoneUsageDescription</key><string>K.A.R.E.N. uses the microphone for speech recognition and wake-word listening.</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>K.A.R.E.N. converts your speech to text on this Mac so it can respond to your requests.</string>
    <key>NSCameraUsageDescription</key><string>K.A.R.E.N. uses the camera only when gesture control is enabled.</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSUIElement</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST

if [ -f "$APP_CONTENTS/Resources/KarenIcon.icns" ]; then
    /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string KarenIcon' "$APP_CONTENTS/Info.plist"
fi
printf 'APPL????' > "$APP_CONTENTS/PkgInfo"

/usr/bin/codesign --force --deep --sign - \
    --options runtime \
    --identifier com.karen.assistant \
    --requirements '=designated => identifier "com.karen.assistant"' \
    "$APP_BUNDLE"

cp "$REPO_ROOT/README-INSTALL.txt" "$BUILD_DIR/staging/Read Me First.txt"
ditto "$APP_BUNDLE" "$BUILD_DIR/staging/K.A.R.E.N..app"
ln -s /Applications "$BUILD_DIR/staging/Applications"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" \
    "$DIST_DIR/K.A.R.E.N.-macos-${ARCH}.zip"
(
    cd "$BUILD_DIR/staging"
    /usr/bin/zip -q -u "$DIST_DIR/K.A.R.E.N.-macos-${ARCH}.zip" "Read Me First.txt"
)
if hdiutil create -volname "K.A.R.E.N." -srcfolder "$BUILD_DIR/staging" \
    -ov -format UDZO "$DIST_DIR/K.A.R.E.N.-macos-${ARCH}.dmg" >/dev/null; then
    echo "Created: $DIST_DIR/K.A.R.E.N.-macos-${ARCH}.dmg"
else
    echo "Warning: this Mac cannot create a disk image here; the ZIP app package is ready." >&2
fi

echo "Created: $DIST_DIR/K.A.R.E.N.-macos-${ARCH}.zip"
