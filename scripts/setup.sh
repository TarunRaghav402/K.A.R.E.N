#!/usr/bin/env bash
# K.A.R.E.N. — Setup Script
# Sets up the Python sidecar venv and verifies prerequisites.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SIDECAR_DIR="$REPO_ROOT/sidecar"
VENV_DIR="$SIDECAR_DIR/.venv"

echo ""
echo "╔═══════════════════════════════════════════╗"
echo "║        K.A.R.E.N.  Setup                 ║"
echo "╚═══════════════════════════════════════════╝"
echo ""

# 1. Check macOS
OS_VER=$(sw_vers -productVersion)
echo "▸ macOS:   $OS_VER"

# 2. Check Swift
SWIFT_VER=$(swift --version 2>&1 | head -1)
echo "▸ Swift:   $SWIFT_VER"


# 3. Check Python 3.13
PYTHON_REQUIRED="3.13"
for p in python3.13 python3 python; do
    if command -v "$p" &>/dev/null; then
        PY_VER=$("$p" --version 2>&1 | awk '{print $2}')
        if [[ "$PY_VER" == ${PYTHON_REQUIRED}* ]]; then
            PYTHON_BIN="$p"
            break
        fi
    fi
done

if [ -z "${PYTHON_BIN:-}" ]; then
    echo "✗ Python 3.13.13 not found. Install Python 3.13 from python.org or brew install python@3.13"
    exit 1
fi
echo "▸ Python:  $PY_VER ($PYTHON_BIN)"

# Keep the repository's interpreter pin aligned with the required compatible series.
if [ "$PY_VER" != "3.13.13" ]; then
    echo "⚠ Python $PY_VER is compatible with the sidecar, but this project targets 3.13.13."
fi

# 4. Create venv
if [ ! -d "$VENV_DIR" ]; then
    echo "▸ Creating venv at $VENV_DIR …"
    "$PYTHON_BIN" -m venv "$VENV_DIR"
else
    echo "▸ Venv:    $VENV_DIR (exists)"
fi

VENV_PY="$VENV_DIR/bin/python3"

# 5. Install dependencies
echo "▸ Installing sidecar dependencies …"
"$VENV_PY" -m pip install --upgrade pip --quiet
"$VENV_PY" -m pip install --upgrade "setuptools>=72" wheel --quiet
"$VENV_PY" -m pip install -e "$SIDECAR_DIR[dev]" --quiet

echo "▸ Dependencies installed"

# 6. Run Python tests
echo ""
echo "▸ Running Python tests …"
cd "$SIDECAR_DIR"
"$VENV_PY" -m pytest tests/ -v --tb=short 2>&1
cd "$REPO_ROOT"

# 7. Build Swift app
echo ""
echo "▸ Building Swift app …"
BUILD_LOG=$(mktemp)
if ! swift build -c release >"$BUILD_LOG" 2>&1; then
    cat "$BUILD_LOG"
    if grep -q "SwiftUIMacros.StateMacro" "$BUILD_LOG"; then
        echo ""
        echo "✗ The selected Apple toolchain is missing the SwiftUI macro plugin."
        echo "  Install Xcode from the App Store or Apple Developer site first."
        echo "  Then select its actual location with: sudo xcode-select --switch /path/to/Xcode.app/Contents/Developer"
        echo "  Check installed locations with: ls -d /Applications/*.app"
    fi
    rm -f "$BUILD_LOG"
    exit 1
fi
cat "$BUILD_LOG"
rm -f "$BUILD_LOG"

echo ""
echo "╔═══════════════════════════════════════════╗"
echo "║  Setup complete! Run:                     ║"
echo "║    bash scripts/run.sh                   ║"
echo "╚═══════════════════════════════════════════╝"
echo ""
echo "Optional: set env vars for a real LLM:"
echo "  export KAREN_LLM_PROVIDER=openai"
echo "  export KAREN_LLM_KEY=sk-..."
echo "  export KAREN_LLM_MODEL=gpt-4o-mini"
