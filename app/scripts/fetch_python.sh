#!/usr/bin/env bash
# Fetch a self-contained python-build-standalone runtime into app/python-dist/.
# Rerunning replaces the existing dist. Requires curl + tar.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$APP_DIR/python-dist"

# Pinned build. Bump deliberately — downstream notarization depends on the
# exact dylibs shipped here.
PYTHON_VERSION="${PYTHON_VERSION:-3.11.9}"
PBS_RELEASE="${PBS_RELEASE:-20240415}"
ARCH="${ARCH:-aarch64}"   # aarch64 for Apple Silicon; x86_64 supported if you need it
BUILD="${BUILD:-apple-darwin-install_only}"

TARBALL="cpython-${PYTHON_VERSION}+${PBS_RELEASE}-${ARCH}-${BUILD}.tar.gz"
URL="https://github.com/indygreg/python-build-standalone/releases/download/${PBS_RELEASE}/${TARBALL}"
PIN_KEY="${PYTHON_VERSION}|${PBS_RELEASE}|${ARCH}|${BUILD}"

case "$PIN_KEY" in
    "3.11.9|20240415|aarch64|apple-darwin-install_only")
        EXPECTED_SHA256="7af7058f7c268b4d87ed7e08c2c7844ef8460863b3e679db3afdce8bb1eedfae"
        ;;
    *)
        echo "[blink] error: no pinned SHA256 for python-build-standalone tuple: $PIN_KEY" >&2
        echo "[blink] update this script from the upstream release asset before downloading:" >&2
        echo "[blink] https://github.com/indygreg/python-build-standalone/releases/tag/$PBS_RELEASE" >&2
        exit 1
        ;;
esac

echo "[blink] fetching $TARBALL"
echo "[blink] from   $URL"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

curl -fsSL --retry 3 -o "$TMP_DIR/$TARBALL" "$URL"
echo "[blink] verifying SHA256"
echo "$EXPECTED_SHA256  $TMP_DIR/$TARBALL" | shasum -a 256 -c -

echo "[blink] extracting → $DIST_DIR"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
tar -xzf "$TMP_DIR/$TARBALL" -C "$DIST_DIR" --strip-components=1

PYTHON_BIN="$DIST_DIR/bin/python3"
if [[ ! -x "$PYTHON_BIN" ]]; then
    echo "[blink] error: expected python3 at $PYTHON_BIN" >&2
    exit 1
fi

echo "[blink] installing google-genai into the dist"
"$PYTHON_BIN" -m pip install --no-warn-script-location --disable-pip-version-check \
    --target "$DIST_DIR/lib/python-packages" \
    -r "$APP_DIR/python/requirements.txt"

echo "[blink] pruning caches"
find "$DIST_DIR" -type d \( -name '__pycache__' -o -name 'tests' \) -prune -exec rm -rf {} + 2>/dev/null || true
find "$DIST_DIR" -type f -name '*.pyc' -delete 2>/dev/null || true

echo "[blink] dist ready: $DIST_DIR"
"$PYTHON_BIN" --version
